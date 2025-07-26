require_relative 'gen_alg'

class BatchGeneticAlgorithm < GeneticAlgorithm
  attr_reader :total_fitness_evaluations

  def initialize(strategy, dimension,
                 mins: nil, maxs: nil, names: nil,
                 bits: 16, logger: nil, seed: nil,
                 input_file: "batch_input.txt",
                 output_file: "batch_output.txt",
                 &fitness)
    super(strategy, dimension, mins: mins, maxs: maxs, names: names,
          bits: bits, logger: logger, seed: seed, &fitness)
    @input_file = input_file
    @output_file = output_file
    @total_fitness_evaluations = 0
  end

  def run
    epoch = 0
    @logger.log('Вычисляем целевую функцию для начальной популяции:')

    batch_evaluate_population(@population)
    @population.sort_by!(&:fitness)

    while epoch < @strategy.iterations
      @logger.log("Эпоха #{epoch}:")

      mutate

      @logger.log('Вычисляем целевые функции новых особей')
      batch_update_fitness

      # Турнир
      @logger.log('Проводим турнир')
      tournament

      # Кроссовер
      @logger.log('Проводим кроссовер')
      crossover

      epoch += 1
      @population.sort_by!(&:fitness)
      best = @population[0]
      @best_history << best.fitness
      @logger.log("Лучший индивидуум: #{format_values(best.values)}, значение функции #{format('%.6e', best.fitness)}")

      break if process_stagnant?
    end

    best = @population.min_by(&:fitness)
    @logger.log("История: #{@best_history}")
    @logger.log("Всего запусков расчета целевой функции: #{@total_fitness_evaluations}")
    @logger.log("Лучший индивидуум: #{format_values(best.values)}, значение функции #{format('%.6e', best.fitness)}")

    # Сохраняем кэш в файл
    save_cache_to_file("optimization_cache_#{@input_file}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")

    best
  end

  private

  def batch_evaluate_population(individuals)
    # Фильтруем только тех, кто нуждается в вычислении
    to_evaluate = individuals.select do |individual|
      !@cache.key?(individual.id) && !find_similar_in_cache(individual)
    end

    return if to_evaluate.empty?

    @logger.log("Пакетное вычисление для #{to_evaluate.size} особей")

    # Записываем данные в input файл
    write_batch_input(to_evaluate)

    # Вызываем внешнюю программу для расчета
    results = call_external_solver

    assign_fitness(to_evaluate, results)

    @total_fitness_evaluations += to_evaluate.size
  end

  def batch_update_fitness
    batch_evaluate_population(@population)
  end

  def write_batch_input(individuals)
    File.open(@input_file, 'w') do |file|
      # Заголовок с именами переменных (должен соответствовать COMSOL модели)
      file.puts @names.join(' ')

      # Данные для каждой особи в том же формате, что ожидает COMSOL
      individuals.each do |individual|
        file.puts individual.values.map { |v| format('%.6f', v) }.join(' ')
      end
    end
    @logger.log("Записано #{individuals.size} особей в файл #{@input_file}")
  end

  def call_external_solver
    @logger.log("Вызываем внешнюю программу для расчета...")

    if @fitness # Для тестирования с функцией Розенброка
      simulate_external_calculation
    else

      raise "Необходимо настроить вызов внешней программы"
    end
  end

  def simulate_external_calculation
    # Симуляция внешнего расчета для тестирования
    @logger.log("Симуляция внешнего расчета...")

    input_data = []
    File.readlines(@input_file).each_with_index do |line, index|
      next if index == 0 # Пропускаем заголовок
      values = line.strip.split.map(&:to_f)
      result = @fitness.call(values)
      input_data << [values, result]
    end

    # Записываем результаты в выходной файл
    File.open(@output_file, 'w') do |file|
      input_data.each do |values, result|
        file.puts "#{values.map { |v| format('%.6f', v) }.join(' ')} #{format('%.16e', result)}"
      end
    end
  end

  def assign_fitness(individuals, results)

    if results.size != individuals.size
      raise "Несоответствие количества результатов: ожидалось #{individuals.size}, получено #{results.size}"
    end

    individuals.each_with_index do |individual, index|
      individual.fitness = results[index]

      @cache[individual.id] = {
        fitness: individual.fitness,
        values: individual.values.dup
      }
    end

    @logger.log("Прочитано #{results.size} результатов из файла #{@output_file}")
  end

  def find_similar_in_cache(individual)
    @cache.find do |_, cached_data|
      close_points?(cached_data[:values], individual.values)
    end
  end

  def update_individual_fitness(individual)
    if @cache.key?(individual.id)
      return
    end

    # Ищем похожую особь в кэше
    similar = find_similar_in_cache(individual)
    if similar
      @logger.log("Особь #{individual.id} похожа на кэшированную, используем сохраненное значение")
      individual.fitness = similar[1][:fitness]
      @cache[individual.id] = {
        fitness: individual.fitness,
        values: individual.values.dup
      }
    end
  end

  def update_fitness
    batch_update_fitness
  end

  def save_cache_to_file(cache_file = nil)
    cache_file = "optimization_cache.json" if cache_file.nil?

    begin
      require 'json'

      cache_data = {
        total_evaluations: @total_fitness_evaluations,
        timestamp: Time.now.strftime("%Y-%m-%d %H:%M:%S"),
        dimension: @dimension,
        names: @names,
        mins: @mins,
        maxs: @maxs,
        cache: @cache
      }

      File.open(cache_file, 'w') do |file|
        file.write(JSON.pretty_generate(cache_data))
      end

      @logger.log("Кэш сохранен в файл #{cache_file} (#{@cache.size} записей)")
    rescue => e
      @logger.log("Ошибка при сохранении кэша: #{e.message}")
    end
  end

  def load_cache_from_file
    cache_file = "optimization_cache.json"

    return unless File.exist?(cache_file)

    begin
      require 'json'

      cache_data = JSON.parse(File.read(cache_file))

      # Проверяем совместимость параметров
      if cache_data['dimension'] == @dimension &&
         cache_data['names'] == @names &&
         cache_data['mins'] == @mins &&
         cache_data['maxs'] == @maxs

        @cache = cache_data['cache'] || {}
        @logger.log("Загружен кэш из файла #{cache_file} (#{@cache.size} записей)")
        @logger.log("Предыдущий запуск: #{cache_data['timestamp']}, всего вычислений: #{cache_data['total_evaluations']}")
      else
        @logger.log("Кэш не совместим с текущими параметрами оптимизации, начинаем с пустого кэша")
      end

    rescue => e
      @logger.log("Ошибка при загрузке кэша: #{e.message}")
    end
  end
end
