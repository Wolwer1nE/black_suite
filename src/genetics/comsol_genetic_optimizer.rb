require_relative '../utils'
require_relative '../problem'
require_relative '../runner'
require_relative 'individual'
require_relative '../simple_logger'
require 'json'

class ComsolGeneticOptimizer
  attr_reader :total_evaluations, :cache, :logger, :best_fitness_history

  def initialize(config)
    @config = config
    @strategy = config.create_genetic_strategy
    @logger = SimpleLogger.new

    setup_parameters
    setup_population
    setup_cache
    setup_comsol
  end

  def optimize
    @logger.log("Запуск генетической оптимизации...")
    @logger.log("Популяция: #{@strategy.population_size}, Поколений: #{@strategy.iterations}")

    evaluate_population(@population)

    @strategy.iterations.times do |generation|
      @generation = generation
      @logger.log("Поколение #{generation + 1}/#{@strategy.iterations}")

      evolve_generation
      evaluate_population(@population)

      log_best_individual(generation)

      break if check_convergence
    end

    save_results
    get_best_individual
  end

  private

  def setup_parameters
    @dimension = @config.dimension
    @names = @config.parameter_names
    @mins = @config.parameter_mins
    @maxs = @config.parameter_maxs
    @work_dir = @config.work_dir
    @total_evaluations = 0
  end

  def setup_population
    @population = []
    @strategy.population_size.times do |i|
      values = generate_random_values
      individual = Individual.new(i, values, mins: @mins, maxs: @maxs, names: @names)
      @population << individual
    end
    @logger.log("Создана популяция из #{@population.size} особей")
  end

  def setup_cache
    @cache = {}
    @best_fitness_history = []  # Массив лучших значений фитнес-функции для каждой эпохи
    #load_existing_cache
  end

  def setup_comsol
    @runner = ComsolRunner.new(@config.comsol_file, @work_dir, 0, "demo_out.txt")
    @logger.log("COMSOL runner настроен для #{@work_dir}/#{@config.comsol_file}")
  end

  def generate_random_values
    @dimension.times.map { |i| @mins[i] + rand * (@maxs[i] - @mins[i]) }
  end

  def evaluate_population(population)
    to_evaluate = filter_unevaluated(population)
    return if to_evaluate.empty?

    @logger.log("Оценка #{to_evaluate.size} особей...")

    param_file = create_parameter_file(to_evaluate)

    results = run_comsol_simulation(param_file, to_evaluate.size)
    assign_fitness_values(to_evaluate, results)

    @total_evaluations += to_evaluate.size
    @logger.log("Обработано #{to_evaluate.size} особей")
  end

  def filter_unevaluated(population)
    population.select { |individual| !cached?(individual) }
  end

  def cached?(individual)
    cache_key = individual.values.map { |v| v.round(8) }.join('_')
    if @cache.key?(cache_key)
      individual.fitness = @cache[cache_key][:fitness]
      true
    else
      false
    end
  end

  def create_parameter_file(individuals)
    param_file = File.join(@work_dir, "batch_params.txt")

    File.open(param_file, 'w') do |file|
      file.puts @names.join(' ')
      individuals.each do |individual|
        file.puts individual.values.map { |v| format('%.8f', v) }.join(' ')
      end
    end

    @logger.log("Создан файл параметров: #{param_file}")
    "batch_params.txt"
  end

  def run_comsol_simulation(param_file, expected_count)
    problem = Problem.new

    begin
      @logger.log("Запуск COMSOL для #{expected_count} точек...")
      problem.solve_problem(@config.method_call,
                                     @runner,
                                     param_file,
                                     silent_mode: @config.silent_output?)

      read_comsol_results(expected_count)
    rescue => e
      @logger.log("Ошибка COMSOL: #{e.message}")
      Array.new(expected_count, Float::INFINITY)
    ensure
      cleanup_temp_files(param_file)
    end
  end

  def read_comsol_results(expected_count)
    output_path = File.join(@runner.work_dir, @runner.output_file)

    if File.exist?(output_path)
      results = File.readlines(output_path).map do |line|
        line.strip.split.last.to_f
      end
      @logger.log("Получено #{results.size} результатов от COMSOL")

      if results.size != expected_count
        @logger.log("ВНИМАНИЕ: ожидалось #{expected_count}, получено #{results.size}")
      end

      results
    else
      @logger.log("ОШИБКА: выходной файл COMSOL не найден")
      Array.new(expected_count, Float::INFINITY)
    end
  end

  def assign_fitness_values(individuals, results)
    individuals.each_with_index do |individual, index|
      fitness = results[index] || Float::INFINITY
      individual.fitness = fitness

      cache_key = individual.values.map { |v| v.round(8) }.join('_')
      @cache[cache_key] = {
        fitness: fitness,
        values: individual.values.dup
      }
    end
  end

  def cleanup_temp_files(param_file)
    File.delete(param_file) if File.exist?(param_file)

    output_path = File.join(@runner.work_dir, @runner.output_file)
    File.delete(output_path) if File.exist?(output_path)
  end

  def evolve_generation
    @population.sort_by!(&:fitness)

    # Анализируем состояние популяции
    analyze_population_diversity
    adapt_parameters

    # Сохраняем элиту БЕЗ мутации
    elite_count = [@strategy.elite_count, 1].max
    elite = @population.first(elite_count)

    # Создаем новое поколение
    new_population = []

    # Добавляем элиту без изменений
    new_population.concat(elite.map { |ind| copy_individual(ind) })

    # Заполняем остальную популяцию
    while new_population.size < @strategy.population_size
      # Адаптивный турнирный отбор
      parent1 = adaptive_tournament_selection
      parent2 = adaptive_tournament_selection

      # Кроссовер с проверкой разнообразия
      children = smart_crossover(parent1, parent2)

      # Адаптивная мутация
      children = children.map { |child| adaptive_mutate(child) }

      # Добавляем детей если есть место
      children.each do |child|
        new_population << child if new_population.size < @strategy.population_size
      end
    end

    @population = new_population
  end

  def analyze_population_diversity
    return if @population.size < 2

    # Вычисляем среднее расстояние между особями
    distances = []
    @population.each_with_index do |ind1, i|
      @population[i+1..-1].each do |ind2|
        distance = euclidean_distance(ind1.values, ind2.values)
        distances << distance
      end
    end

    @diversity = distances.empty? ? 0 : distances.sum / distances.size
    @logger.log("Разнообразие популяции: #{@diversity.round(6)}")
  end

  def euclidean_distance(values1, values2)
    sum = values1.zip(values2).map { |v1, v2| (v1 - v2) ** 2 }.sum
    Math.sqrt(sum)
  end

  def adapt_parameters
    # Адаптируем размер турнира в зависимости от поколения
    progress = (@generation || 0).to_f / @strategy.iterations

    # В начале - больше исследования (меньший турнир)
    # В конце - больше эксплуатации (большой турнир)
    @current_tournament_size = [2 + (progress * 3).round, 7].min

    # Адаптируем мутацию в зависимости от разнообразия
    @current_mutation_rate = if @diversity && @diversity < 0.001
      [@strategy.mutation_prob * 2, 0.5].min  # Увеличиваем при низком разнообразии
    else
      @strategy.mutation_prob
    end

    @logger.log("Адаптация: турнир=#{@current_tournament_size}, мутация=#{(@current_mutation_rate*100).round(1)}%")
  end

  def adaptive_tournament_selection
    candidates = @population.sample(@current_tournament_size)

    # Добавляем элемент случайности для поддержания разнообразия
    if rand < 0.1  # 10% шанс выбрать не лучшего
      candidates.sample
    else
      candidates.min_by(&:fitness)
    end
  end

  def smart_crossover(parent1, parent2)
    # Проверяем, насколько похожи родители
    distance = euclidean_distance(parent1.values, parent2.values)

    # Вычисляем относительный порог на основе размера области поиска
    max_possible_distance = euclidean_distance(@mins, @maxs)
    relative_threshold = max_possible_distance * 0.05  # 5% от максимального расстояния

    if distance < relative_threshold  # Относительно похожие родители
      # Принудительно создаем разнообразие
      child1 = copy_individual(parent1)
      child2 = generate_diverse_individual(parent1)
      [child1, child2]
    else
      # Обычный кроссовер
      perform_crossover([parent1, parent2])
    end
  end

  def perform_crossover(parents)
    parent1, parent2 = parents

    if rand < @strategy.crossover_prob
      actual_crossover(parent1, parent2)
    else
      [copy_individual(parent1), copy_individual(parent2)]
    end
  end

  def actual_crossover(parent1, parent2)
    # Используем бинарное представление для кроссовера
    genome1 = parent1.genome
    genome2 = parent2.genome

    # Одноточечный кроссовер по геному
    crossover_point = rand(genome1.length)

    child1_genome = genome1[0...crossover_point] + genome2[crossover_point..-1]
    child2_genome = genome2[0...crossover_point] + genome1[crossover_point..-1]

    # Создаем новых особей и декодируем геномы в значения
    child1 = Individual.new(next_id, parent1.values.dup, mins: @mins, maxs: @maxs, names: @names)
    child2 = Individual.new(next_id, parent2.values.dup, mins: @mins, maxs: @maxs, names: @names)

    child1.genome = child1_genome
    child2.genome = child2_genome

    child1.values = child1.decode
    child2.values = child2.decode

    [child1, child2]
  end

  def generate_diverse_individual(reference)
    # Создаем копию reference и мутируем её через бинарное представление
    diverse_individual = copy_individual(reference)

    # Применяем сильную бинарную мутацию для создания разнообразия
    # Увеличиваем скорость мутации до 0.1 (10% битов)
    heavily_mutated = diverse_individual.mutate(mutation_rate: 0.1)
    heavily_mutated.id = next_id

    heavily_mutated
  end

  def adaptive_mutate(individual)
    # Используем адаптивную скорость мутации
    mutated = individual.mutate(mutation_rate: @current_mutation_rate)
    mutated.id = next_id
    mutated
  end

  def copy_individual(individual)
    Individual.new(next_id, individual.values.dup, mins: @mins, maxs: @maxs, names: @names)
  end

  def next_id
    @next_id ||= @population.size
    @next_id += 1
  end

  def log_best_individual(generation)
    best = @population.min_by(&:fitness)
    @best_fitness_history << best.fitness  # Сохраняем лучшее значение фитнес-функции для текущей эпохи
    @logger.log("Лучший: #{format_individual(best)}")
  end

  def format_individual(individual)
    params = individual.values.map.with_index do |val, i|
      "#{@names[i]}=#{val.round(6)}"
    end.join(', ')

    "#{params}, fitness=#{individual.fitness.round(4)}"
  end
  def process_stagnant?
    return false if @best_fitness_history.size < @strategy.max_stagnant_epochs

    last = @best_fitness_history.last
    @best_fitness_history.last(@strategy.max_stagnant_epochs).all? do |x|
      (x-last).abs < @strategy.epsilon
    end
  end
  def check_convergence
    return true if process_stagnant?
    false
  end

  def get_best_individual
    @population.min_by(&:fitness)
  end

  def load_existing_cache
    cache_file = File.join(@work_dir, @config.cache_file)
    return unless File.exist?(cache_file)

    begin
      cache_data = JSON.parse(File.read(cache_file))

      if cache_compatible?(cache_data)
        @cache = cache_data['cache'] || {}
        @best_fitness_history = cache_data['best_fitness_history'] || []  # Загружаем историю лучших значений
        @logger.log("Загружен кэш: #{@cache.size} записей")
        @logger.log("Загружена история фитнес-функции: #{@best_fitness_history.size} эпох") if @best_fitness_history.any?
      else
        @logger.log("Кэш несовместим, начинаем с пустого")
      end
    rescue => e
      @logger.log("Ошибка загрузки кэша: #{e.message}")
    end
  end

  def cache_compatible?(cache_data)
    cache_data['dimension'] == @dimension &&
    cache_data['names'] == @names &&
    cache_data['mins'] == @mins &&
    cache_data['maxs'] == @maxs &&
    cache_data['comsol_file'] == @config.comsol_file &&
    cache_data['methodcall'] == @config.method_call
  end

  def save_results
    save_cache
    log_final_statistics
  end

  def save_cache
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    cache_file = File.join(@work_dir, "optimization_cache_#{timestamp}.json")

    cache_data = {
      total_evaluations: @total_evaluations,
      timestamp: Time.now.strftime("%Y-%m-%d %H:%M:%S"),
      dimension: @dimension,
      names: @names,
      mins: @mins,
      maxs: @maxs,
      comsol_file: @config.comsol_file,
      methodcall: @config.method_call,
      best_fitness_history: @best_fitness_history,
      cache: @cache
    }

    File.write(cache_file, JSON.pretty_generate(cache_data))
    @logger.log("Кэш сохранен: #{cache_file}")
  end

  def log_final_statistics
    best = get_best_individual
    @logger.log("Оптимизация завершена!")
    @logger.log("Всего оценок: #{@total_evaluations}")
    @logger.log("Лучший результат: #{format_individual(best)}")
  end
end
