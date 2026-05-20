# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'shape_optimization_config'

# Параллельная fitness-функция для оптимизации формы
# Запускает несколько экземпляров acli одновременно в разных рабочих каталогах
class ParallelFormOptimizationFitness
  attr_reader :config, :evaluation_count, :max_workers

  # @param config [ShapeOptimizationConfig] конфигурация оптимизации
  # @param max_workers [Integer] максимальное количество параллельных процессов
  def initialize(config, max_workers: 8)
    @config = config
    @max_workers = max_workers
    @evaluation_count = 0
    @mutex = Mutex.new
  end

  # Вычисляет значения целевой функции для массива векторов (пакетная оценка)
  # @param population [Array<Array<Float>>] массив векторов коэффициентов
  # @return [Array<Float>] массив значений fitness
  def evaluate_batch(population)
    puts "\n=== Пакетная оценка: #{population.size} особей ==="
    
    results = Array.new(population.size, Float::INFINITY)
    
    # Разбиваем на батчи по max_workers
    population.each_slice(@max_workers).with_index do |batch, batch_idx|
      puts "Батч #{batch_idx + 1}: #{batch.size} вычислений"
      
      # Запускаем параллельно
      threads = batch.map.with_index do |coefficients, local_idx|
        Thread.new do
          global_idx = batch_idx * @max_workers + local_idx
          results[global_idx] = evaluate_single(coefficients, global_idx)
        end
      end
      
      # Ждём завершения батча
      threads.each(&:join)
    end
    
    puts "✓ Пакетная оценка завершена"
    results
  end

  # Вычисляет fitness для одного вектора (однопоточная версия для совместимости)
  # @param coefficients [Array<Float>] вектор коэффициентов
  # @return [Float] значение fitness
  def call(coefficients)
    eval_id = increment_counter
    evaluate_single(coefficients, eval_id)
  end

  private

  def increment_counter
    @mutex.synchronize { @evaluation_count += 1 }
  end

  def evaluate_single(coefficients, eval_id)
    eval_num = eval_id + 1
    puts "\n--- Вычисление ##{eval_num} (ID: #{eval_id}) ---"
    
    # Создаём отдельный рабочий каталог для этого вычисления с timestamp для уникальности
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S_%L')
    worker_dir = File.join(@config.work_dir, "worker_#{eval_id}_#{timestamp}")
    FileUtils.mkdir_p(worker_dir)
    
    # Генерируем файл с коэффициентами с уникальным именем
    shift_coef_file = File.join(worker_dir, "shift_coefficients_#{eval_id}_#{timestamp}.txt")
    File.open(shift_coef_file, 'w') do |file|
      coefficients.each { |coef| file.puts coef }
    end
    
    puts "Коэффициенты: [#{coefficients.first(3).map { |v| format('%.6f', v) }.join(', ')}#{coefficients.size > 3 ? ', ...' : ''}]"

    # Копируем normals.txt в рабочий каталог с уникальным именем
    normals_copy = File.join(worker_dir, "normals_#{eval_id}_#{timestamp}.txt")
    FileUtils.cp(@config.normals_file, normals_copy)
    
    # Ждём пока файлы станут доступны для чтения (освобождены Windows)
    wait_for_file_unlocked(shift_coef_file)
    wait_for_file_unlocked(normals_copy)

    # Создаём form_opt.json для этого вычисления
    form_config = create_worker_config(worker_dir, shift_coef_file, normals_copy)

    # Выполняем bs-form-opt
    execute_form_optimization(worker_dir, form_config, eval_id)

    # Читаем значение целевой функции
    goals_file = File.join(worker_dir, 'goals.txt')
    fitness = read_goal_value(goals_file)
    
    puts "Fitness ##{eval_num}: #{format('%.6e', fitness)}"
    fitness
    
  rescue StandardError => e
    puts "Ошибка при вычислении fitness ##{eval_num}: #{e.message}"
    puts e.backtrace.first(5).join("\n")
    Float::INFINITY
  end

  def create_worker_config(worker_dir, shift_coef_file, normals_file)
    template_path = File.join('templates', 'form_opt.json')
    template = JSON.parse(File.read(template_path))
    
    data = template['DataFormOptimizationBS']['DataModel']
    data['mesh'] = @config.mesh_file
    settings = @config.inferred_model_settings
    data['variables'] = settings[:variables]
    data['elementData'] ||= {}
    data['elementData']['elementType'] = settings[:element_type]
    data['elementData']['elementOrder'] = settings[:element_order]
    
    # Используем абсолютные пути
    template['DataFormOptimizationBS']['shiftCoefficients'] = File.absolute_path(shift_coef_file)
    template['DataFormOptimizationBS']['normals'] = File.absolute_path(normals_file)

    config_file = File.join(worker_dir, 'form_opt.json')
    File.open(config_file, 'w') do |file|
      file.write(JSON.pretty_generate(template))
    end
    
    config_file
  end

  def execute_form_optimization(worker_dir, config_file, eval_id)
    output_jam = File.join(worker_dir, 'form_opt.jam')
    
    abs_config_file = File.absolute_path(config_file)
    abs_output_jam = File.absolute_path(output_jam)
    
    command = "acli bs-form-opt \"#{abs_config_file}\" \"#{abs_output_jam}\""
    
    Dir.chdir(worker_dir) do
      out_log = 'form_opt_out.log'
      err_log = 'form_opt_err.log'
      
      pid = spawn(command, 
                  in: 'NUL',
                  out: out_log, 
                  err: err_log)
      Process.wait(pid)
      exit_status = $?.exitstatus
      
      if exit_status.nil? || exit_status != 0
        err_content = File.exist?(err_log) ? File.read(err_log).lines.first(10).join : 'лог пуст'
        raise "Ошибка выполнения acli bs-form-opt (код: #{exit_status.inspect})\nЛог ошибок:\n#{err_content}"
      end
    end

    check_form_opt_status(output_jam)
  end

  def check_form_opt_status(jam_file)
    unless File.exist?(jam_file)
      raise "Файл #{jam_file} не найден"
    end

    jam_data = JSON.parse(File.read(jam_file))
    status = jam_data.dig('metaData', 'status') || jam_data.dig('metadata', 'status')

    unless status&.downcase == 'success'
      raise "Ошибка выполнения bs-form-opt: status = #{status.inspect}"
    end
  end

  def read_goal_value(goals_file)
    unless File.exist?(goals_file)
      raise "Файл целевой функции не найден: #{goals_file}"
    end

    File.read(goals_file).strip.to_f
  end

  def wait_for_file_unlocked(filepath, max_attempts: 20, delay: 0.05)
    max_attempts.times do |attempt|
      begin
        # Пытаемся открыть файл для чтения — если успешно, значит не заблокирован
        File.open(filepath, 'r') { |f| f.read(1) }
        return true
      rescue Errno::EACCES, Errno::ENOENT, IOError
        sleep delay if attempt < max_attempts - 1
      end
    end
    
    # Если не удалось — предупреждаем, но продолжаем
    puts "⚠ Предупреждение: файл #{filepath} может быть заблокирован"
    true
  end
end
