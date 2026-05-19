# frozen_string_literal: true

require 'json'
require 'ostruct'
require_relative '../problem'
require_relative '../runner'
require_relative '../simple_logger'
require_relative 'acquisition'
require_relative 'surrogate_dataset'
require_relative 'surrogate_backends/inverse_distance_backend'
require_relative '../../tools/lhs'

# Гибридный параметрический оптимизатор для дорогих black-box задач.
# Комбинирует:
# - исторические кэши,
# - LHS/случайное исследование,
# - surrogate-driven выбор кандидатов,
# - локальную эксплуатацию около текущего лучшего решения,
# - батч-запуск COMSOL.
class HybridAIOptimizer
  attr_reader :dataset, :logger, :total_evaluations, :best_fitness_history, :cache

  def initialize(config, logger: SimpleLogger.new, backend: nil)
    @config = config
    @logger = logger
    @rng = Random.new(config.ai_options.fetch('seed', Random.new_seed))

    setup_problem
    setup_ai_components(backend)
    setup_runner
  end

  def optimize
    log("Запуск hybrid AI оптимизации для #{@dimension} параметров")
    import_historical_data
    bootstrap_dataset_if_needed

    @max_iterations.times do |iteration|
      @current_iteration = iteration + 1
      fit_surrogate

      candidates = propose_candidates
      break if candidates.empty?

      results = evaluate_candidates(candidates)
      @dataset.add_batch(candidates, results, source: 'hybrid_ai')
      synchronize_cache_from_dataset

      best = @dataset.best_entry
      @best_fitness_history << best.fitness
      log_iteration_summary(best, candidates.size)

      break if target_reached?
      break if stagnant?
    end

    save_results
    OpenStruct.new(values: @dataset.best_sample, fitness: @dataset.best_fitness)
  end

  private

  def setup_problem
    @dimension = @config.dimension
    @names = @config.parameter_names
    @mins = @config.parameter_mins.map(&:to_f)
    @maxs = @config.parameter_maxs.map(&:to_f)
    @work_dir = @config.work_dir
    @total_evaluations = 0
    @best_fitness_history = []
    @cache = {}
  end

  def setup_ai_components(backend)
    @ai_options = {
      'seed' => Random.new_seed,
      'initial_samples' => [@dimension * 4, 8].max,
      'batch_size' => [@dimension, 2].max,
      'candidate_pool_size' => [@dimension * 20, 40].max,
      'max_iterations' => @config.max_generations,
      'exploration_ratio' => 0.55,
      'local_radius' => 0.15,
      'local_radius_decay' => 0.97,
      'min_distance_threshold' => 0.02 * Math.sqrt(@dimension),
      'acquisition' => 'expected_improvement',
      'kappa' => 2.0,
      'xi' => 0.01,
      'target_fitness' => nil,
      'import_existing_cache' => true,
      'historical_cache_glob' => 'optimization_cache*.json'
    }.merge(@config.ai_options)

    @dataset = SurrogateDataset.new(names: @names, mins: @mins, maxs: @maxs)
    @backend = backend || InverseDistanceBackend.new(k_neighbors: [@dimension * 2, 8].max)
    @acquisition = Acquisition.new(
      mode: @ai_options['acquisition'],
      kappa: @ai_options['kappa'],
      xi: @ai_options['xi']
    )
    @batch_size = @ai_options['batch_size'].to_i
    @candidate_pool_size = @ai_options['candidate_pool_size'].to_i
    @max_iterations = @ai_options['max_iterations'].to_i
    @min_distance_threshold = @ai_options['min_distance_threshold'].to_f
  end

  def setup_runner
    @runner = ComsolRunner.new(@config.comsol_file, @work_dir, 0, 'hybrid_ai_out.txt')
  end

  def import_historical_data
    return unless @ai_options['import_existing_cache']

    pattern = File.join(@work_dir, @ai_options['historical_cache_glob'])
    imported = Dir.glob(pattern).sum do |file_path|
      @dataset.import_cache_file(file_path)
    end

    synchronize_cache_from_dataset
    log("Импортировано #{imported} исторических точек из кэша") if imported.positive?
  end

  def bootstrap_dataset_if_needed
    required = @ai_options['initial_samples'].to_i
    missing = required - @dataset.size
    return if missing <= 0

    log("Недостаточно данных для surrogate, добираем #{missing} стартовых точек")
    bootstrap_points = generate_lhs_points(missing)
    results = evaluate_candidates(bootstrap_points)
    @dataset.add_batch(bootstrap_points, results, source: 'bootstrap_lhs')
    synchronize_cache_from_dataset
  end

  def fit_surrogate
    raise 'Нет данных для обучения surrogate' if @dataset.empty?

    @backend.fit(@dataset.samples, @dataset.fitnesses, mins: @mins, maxs: @maxs)
  end

  def propose_candidates
    pool = build_candidate_pool
    scored = pool.map do |candidate|
      prediction = @backend.predict(candidate)
      score = @acquisition.score(prediction, best_fitness: @dataset.best_fitness)
      {
        values: candidate,
        prediction: prediction,
        score: score
      }
    end

    scored.sort_by! { |entry| -entry[:score] }

    selected = []
    scored.each do |entry|
      values = entry[:values]
      next if too_close_to_selected?(values, selected)

      selected << values
      break if selected.size >= @batch_size
    end

    if selected.empty?
      fallback = generate_lhs_points(@batch_size)
      return fallback.reject { |point| @dataset.include_close_sample?(point, threshold: @min_distance_threshold) }.first(@batch_size)
    end

    selected
  end

  def build_candidate_pool
    exploration_count = (@candidate_pool_size * @ai_options['exploration_ratio'].to_f).round
    exploitation_count = [@candidate_pool_size - exploration_count, 0].max

    candidates = []
    candidates.concat(generate_lhs_points(exploration_count))
    candidates.concat(generate_local_candidates(exploitation_count))

    candidates.reject! do |candidate|
      @dataset.include_close_sample?(candidate, threshold: @min_distance_threshold)
    end

    deduplicate_points(candidates)
  end

  def generate_lhs_points(count)
    return [] if count <= 0

    LHS.sample(count, @dimension, @mins, @maxs, rng: @rng)
  end

  def generate_local_candidates(count)
    return [] if count <= 0
    return generate_lhs_points(count) if @dataset.best_sample.nil?

    center = @dataset.best_sample
    decay = @ai_options['local_radius_decay'].to_f ** [@current_iteration.to_i - 1, 0].max
    radius_scale = @ai_options['local_radius'].to_f * decay

    Array.new(count) do
      center.each_with_index.map do |value, idx|
        range = @maxs[idx] - @mins[idx]
        delta = random_normal * range * radius_scale
        (value + delta).clamp(@mins[idx], @maxs[idx])
      end
    end
  end

  def evaluate_candidates(candidates)
    return [] if candidates.empty?

    log("Оценка #{candidates.size} кандидатов через COMSOL")
    param_file = create_parameter_file(candidates)

    begin
      Problem.new.solve_problem(
        @config.method_call,
        @runner,
        param_file,
        silent_mode: @config.silent_output?
      )
      results = read_comsol_results(candidates.size)
      @total_evaluations += candidates.size
      results
    rescue StandardError => e
      log("Ошибка COMSOL: #{e.message}")
      Array.new(candidates.size, Float::INFINITY)
    ensure
      cleanup_temp_files(param_file)
    end
  end

  def create_parameter_file(candidates)
    param_file = File.join(@work_dir, 'hybrid_batch_params.txt')

    File.open(param_file, 'w') do |file|
      file.puts @names.join(' ')
      candidates.each do |candidate|
        file.puts candidate.map { |value| format('%.8f', value) }.join(' ')
      end
    end

    File.basename(param_file)
  end

  def read_comsol_results(expected_count)
    output_path = File.join(@runner.work_dir, @runner.output_file)
    return Array.new(expected_count, Float::INFINITY) unless File.exist?(output_path)

    results = File.readlines(output_path).map do |line|
      line.strip.split.last.to_f
    end

    while results.size < expected_count
      results << Float::INFINITY
    end

    results.first(expected_count)
  end

  def cleanup_temp_files(param_file)
    param_path = File.join(@work_dir, param_file)
    File.delete(param_path) if File.exist?(param_path)

    output_path = File.join(@runner.work_dir, @runner.output_file)
    File.delete(output_path) if File.exist?(output_path)
  rescue StandardError => e
    log("Предупреждение: не удалось очистить временные файлы: #{e.message}")
  end

  def synchronize_cache_from_dataset
    @cache = @dataset.cache_hash
  end

  def too_close_to_selected?(candidate, selected)
    selected.any? do |existing|
      @dataset.normalized_distance(candidate, existing) <= @min_distance_threshold
    end
  end

  def deduplicate_points(points)
    unique = []
    points.each do |point|
      next if too_close_to_selected?(point, unique)

      unique << point
    end
    unique
  end

  def target_reached?
    target = @ai_options['target_fitness']
    target && @dataset.best_fitness <= target.to_f
  end

  def stagnant?
    return false if @best_fitness_history.size < @config.create_genetic_strategy.max_stagnant_epochs

    last = @best_fitness_history.last
    @best_fitness_history.last(@config.create_genetic_strategy.max_stagnant_epochs).all? do |value|
      (value - last).abs < @config.create_genetic_strategy.epsilon
    end
  end

  def save_results
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    cache_file = File.join(@work_dir, "optimization_cache_hybrid_ai_#{timestamp}.json")

    cache_data = {
      optimizer: 'hybrid_ai',
      total_evaluations: @total_evaluations,
      timestamp: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
      dimension: @dimension,
      names: @names,
      mins: @mins,
      maxs: @maxs,
      comsol_file: @config.comsol_file,
      methodcall: @config.method_call,
      best_fitness_history: @best_fitness_history,
      ai_options: @ai_options,
      cache: @cache
    }

    File.write(cache_file, JSON.pretty_generate(cache_data))
    log("Hybrid AI кэш сохранен: #{cache_file}")
  end

  def log_iteration_summary(best, batch_size)
    params = best.values.map.with_index do |value, idx|
      "#{@names[idx]}=#{value.round(6)}"
    end.join(', ')

    log("Итерация #{@current_iteration}: batch=#{batch_size}, best=#{best.fitness.round(6)} (#{params})")
  end

  def log(message)
    @logger.log(message)
  end

  def random_normal
    u1 = [@rng.rand, 1e-12].max
    u2 = @rng.rand
    Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * u2)
  end
end
