# frozen_string_literal: true

require 'fileutils'
require 'securerandom'
require 'rbconfig'
require 'thread'

class ShapeOptimizationJobManager
  def initialize(root_dir)
    @root_dir = File.expand_path(root_dir)
    @jobs_dir = File.join(@root_dir, 'work_dir', 'ui_jobs')
    FileUtils.mkdir_p(@jobs_dir)
    @jobs = {}
    @mutex = Mutex.new
  end

  def start_or_reuse_job(shape_id:, mesh_path:, options:)
    @mutex.synchronize do
      normalized = normalized_options(options)
      existing_job = @jobs.values.find do |job|
        job[:shape_id] == shape_id && job[:options] == normalized && running_status?(refresh_job_state!(job))
      end
      return serialize_job(existing_job, reused: true) if existing_job

      session_name = options[:session_name].to_s.strip
      session_name = default_session_name(shape_id) if session_name.empty?

      job_id = SecureRandom.uuid
      log_path = File.join(@jobs_dir, "shape_optimization_#{job_id}.log")
      command_args = build_command_args(mesh_path, session_name, options)
      pid = spawn(*command_args, chdir: @root_dir, in: 'NUL', out: log_path, err: log_path)

      job = {
        id: job_id,
        pid: pid,
        shape_id: shape_id,
        mesh_path: File.expand_path(mesh_path),
        session_name: session_name,
        log_path: log_path,
        command_args: command_args,
        options: normalized,
        status: 'running',
        phase: 'queued',
        started_at: Time.now,
        finished_at: nil,
        exit_code: nil,
        current_generation: 0,
        current_evaluations: 0,
        best_fitness: nil,
        progress_percent: 0.0,
        recent_log_lines: []
      }

      @jobs[job_id] = job
      serialize_job(job, reused: false)
    end
  end

  def active_job_for_shape(shape_id)
    @mutex.synchronize do
      job = @jobs.values.find do |entry|
        entry[:shape_id] == shape_id && running_status?(refresh_job_state!(entry))
      end
      job && serialize_job(job)
    end
  end

  def job_status(job_id)
    @mutex.synchronize do
      job = @jobs[job_id]
      return nil unless job

      refresh_job_state!(job)
      serialize_job(job)
    end
  end

  private

  def build_command_args(mesh_path, session_name, options)
    args = [
      RbConfig.ruby,
      File.join(@root_dir, 'shape_optimization.rb'),
      File.expand_path(mesh_path),
      '--session', session_name,
      '--sigma', options[:sigma].to_s,
      '--max-evals', options[:max_evaluations].to_s,
      '--max-gen', options[:max_generations].to_s
    ]

    args += ['--target', options[:target_fitness].to_s] if options[:target_fitness]

    args += ['--pre-smoothing', options[:pre_smoothing_mode].to_s]
    args += ['--smooth-iterations', options[:smooth_iterations].to_s]
    args += ['--smooth-lambda', options[:smooth_lambda].to_s]
    args += ['--smooth-mu', options[:smooth_mu].to_s] unless options[:smooth_mu].nil?
    args += ['--smooth-max-step', options[:smooth_max_step].to_s] unless options[:smooth_max_step].nil?

    if options[:parallel]
      args += ['--workers', options[:workers].to_s]
    else
      args << '--no-parallel'
    end

    args
  end

  def normalized_options(options)
    {
      sigma: options[:sigma].to_f,
      max_evaluations: options[:max_evaluations].to_i,
      max_generations: options[:max_generations].to_i,
      target_fitness: options[:target_fitness],
      workers: options[:workers].to_i,
      parallel: !!options[:parallel],
      pre_smoothing_mode: options[:pre_smoothing_mode].to_s,
      smooth_iterations: options[:smooth_iterations].to_i,
      smooth_lambda: options[:smooth_lambda].to_f,
      smooth_mu: options[:smooth_mu].nil? ? nil : options[:smooth_mu].to_f,
      smooth_max_step: options[:smooth_max_step].nil? ? nil : options[:smooth_max_step].to_f
    }
  end

  def default_session_name(shape_id)
    "ui_shape_opt_#{shape_id}_#{Time.now.strftime('%Y%m%d_%H%M%S')}"
  end

  def refresh_job_state!(job)
    if running_status?(job)
      wait_result = Process.waitpid2(job[:pid], Process::WNOHANG)
      if wait_result
        _pid, process_status = wait_result
        job[:exit_code] = process_status.exitstatus
        job[:finished_at] = Time.now
        job[:status] = process_status.success? ? 'completed' : 'failed'
      end
    end

    parse_log!(job)
    job
  rescue Errno::ECHILD
    job[:status] = 'failed'
    job[:finished_at] ||= Time.now
    job[:exit_code] ||= -1
    parse_log!(job)
    job
  end

  def parse_log!(job)
    lines = read_log_lines(job[:log_path])
    job[:recent_log_lines] = lines.last(40)

    options = job[:options]
    max_generations = [options[:max_generations].to_i, 1].max
    max_evaluations = [options[:max_evaluations].to_i, 1].max

    last_generation_line = lines.reverse.find { |line| line =~ /Gen\s+(\d+):\s+best=([^\s]+).*evals=(\d+)/ }
    if last_generation_line && (match = last_generation_line.match(/Gen\s+(\d+):\s+best=([^\s]+).*evals=(\d+)/))
      job[:current_generation] = match[1].to_i
      job[:best_fitness] = match[2].to_f
      job[:current_evaluations] = match[3].to_i
    end

    if (result_line = lines.reverse.find { |line| line =~ /Лучшее значение fitness:\s+([^\s]+)/ })
      job[:best_fitness] = result_line.match(/Лучшее значение fitness:\s+([^\s]+)/)[1].to_f
    end

    if (gen_line = lines.reverse.find { |line| line =~ /Поколений:\s+(\d+)/ })
      job[:current_generation] = gen_line.match(/Поколений:\s+(\d+)/)[1].to_i
    end

    if (eval_line = lines.reverse.find { |line| line =~ /Вычислений fitness:\s+(\d+)/ })
      job[:current_evaluations] = eval_line.match(/Вычислений fitness:\s+(\d+)/)[1].to_i
    end

    last_live_evaluation = lines.filter_map do |line|
      match = line.match(/Вычисление\s+#(\d+)/)
      match && match[1].to_i
    end.max
    job[:current_evaluations] = [job[:current_evaluations].to_i, last_live_evaluation.to_i].max if last_live_evaluation

    live_fitness = lines.reverse.find { |line| line =~ /Fitness(?:\s+#\d+)?:\s+([^\s]+)/ }
    if live_fitness && (match = live_fitness.match(/Fitness(?:\s+#\d+)?:\s+([^\s]+)/))
      candidate = match[1].to_f
      job[:best_fitness] = [job[:best_fitness], candidate].compact.min
    end

    job[:phase] =
      if lines.any? { |line| line.include?('Оптимизация завершена') || line.include?('Готово!') }
        'completed'
      elsif lines.any? { |line| line.include?('Запуск CMA-ES оптимизации') }
        'optimizing'
      elsif lines.any? { |line| line.include?('Извлечение границ смещений') }
        'extracting_boundaries'
      else
        'queued'
      end

    raw_progress = [
      job[:current_generation].to_f / max_generations,
      job[:current_evaluations].to_f / max_evaluations
    ].max

    job[:progress_percent] = case job[:status]
                             when 'completed'
                               100.0
                             when 'failed'
                               [raw_progress * 100.0, 100.0].min
                             else
                               case job[:phase]
                               when 'queued'
                                 2.0
                               when 'extracting_boundaries'
                                 8.0
                               when 'optimizing'
                                 10.0 + [raw_progress, 1.0].min * 85.0
                               else
                                 [raw_progress, 1.0].min * 100.0
                               end
                             end
  end

  def read_log_lines(path)
    return [] unless File.exist?(path)

    File.read(path, encoding: 'bom|utf-8', invalid: :replace, undef: :replace, replace: '?').split(/\r?\n/)
  rescue StandardError
    []
  end

  def serialize_job(job, reused: false)
    {
      id: job[:id],
      shape_id: job[:shape_id],
      session_name: job[:session_name],
      status: job[:status],
      phase: job[:phase],
      progress_percent: job[:progress_percent].round(1),
      current_generation: job[:current_generation],
      max_generations: job[:options][:max_generations],
      current_evaluations: job[:current_evaluations],
      max_evaluations: job[:options][:max_evaluations],
      best_fitness: job[:best_fitness],
      started_at: job[:started_at]&.iso8601,
      finished_at: job[:finished_at]&.iso8601,
      exit_code: job[:exit_code],
      options: job[:options],
      recent_log_lines: job[:recent_log_lines],
      reused: reused
    }
  end

  def running_status?(job)
    %w[running queued].include?(job[:status])
  end
end
