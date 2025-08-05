require_relative 'individual'
require_relative 'genetic_strategy'

class GeneticAlgorithm
  # @param [GeneticStrategy] strategy
  # @param [Integer] dimension
  def initialize(strategy,
                 dimension,
                 mins: nil, maxs: nil, names: nil,
                 bits: 16, logger: nil, seed: nil, &fitness)
    @strategy = strategy
    @dimension = dimension
    @bits = bits
    @fitness = fitness
    @logger = logger
    @mins = mins || Array.new(@dimension, -1.0)
    @maxs = maxs || Array.new(@dimension, 1.0)
    @names = names || Array.new(@dimension) { |i| "x#{i+1}" }
    @next_id = 0
    @best_history = []

    @population = Array.new(@strategy.population_size) do
      values = Array.new(@dimension) { |i| rand(@mins[i]..@maxs[i]) }
      individual = Individual.new(@next_id, values, mins: @mins, maxs: @maxs, names: @names)
      @next_id += 1
      individual
    end
    @logger.log("Создана начальная популяция из #{@strategy.population_size} особей")
    @cache = {}
    @total_fitness_runs = 0

  end



  def run

    epoch = 0
    @logger.log('Вычисляем целевую функцию для начальной популяции:')
    @population.each do |individual|
      individual.compute_fitness(&@fitness)
      @cache[individual.id] = {fitness: individual.fitness, values: individual.values}
    end
    @population.sort_by!(&:fitness)

    while epoch < @strategy.iterations
      @logger.log("Эпоха #{epoch}:")
      # Мutation
      mutate
      @logger.log('Вычисляем целевые функции новых особей')
      update_fitness
      @logger.log('Проводим турнир')
      tournament
      @logger.log('Проводим кроссовер')
      crossover


      epoch += 1
      @population.sort_by!(&:fitness)
      best = @population[0]
      @best_history << best.fitness
      @logger.log("Лучший индивидуум: #{format_values(best.values)}, значение функции #{format('%.6e', best.fitness(&@fitness))}")

      break if process_stagnant?
    end
    best = @population.min_by(&:fitness)
    @logger&.log("История:")
    @logger.log(@best_history)
    @logger.log("Всего запусков расчета целевой функции: #{@total_fitness_runs}")
    @logger.log("Лучший индивидуум: #{format_values(best.values)}, значение функции #{format('%.6e', best.fitness(&@fitness))}")
    best
  end

  def process_stagnant?
    return false if @best_history.size < @strategy.max_stagnant_epochs

    last = @best_history.last
    @best_history.last(@strategy.max_stagnant_epochs).all? do |x|
      (x-last).abs < @strategy.epsilon
    end
  end

  def crossover
    # Количество пар для кроссовера
    num_pairs = (@population.size * @strategy.crossover_prob / 2).round

    # Создаем новых потомков
    offspring = []

    num_pairs.times do
      # Выбираем родителей турнирным отбором
      parent1 = tournament_selection
      parent2 = tournament_selection

      # Убеждаемся, что родители разные
      next if parent1 == parent2

      kid1, kid2 = crossover_pair(parent1, parent2)
      if kid1 && kid2
        update_individual_fitness(kid1)
        update_individual_fitness(kid2)
        offspring << kid1
        offspring << kid2
      end
    end

    # Заменяем худших особей новыми потомками
    if !offspring.empty?
      @population.sort_by!(&:fitness)
      replacement_count = [offspring.size, @population.size - @strategy.elite_count].min

      offspring.sort_by!(&:fitness)
      (0...replacement_count).each do |i|
        @population[@population.size - 1 - i] = offspring[i]
      end
    end
  end

  def mutate
    # Сохраняем элитных особей
    elite_individuals = @population[0...@strategy.elite_count].dup

    @population.map! do |individual|
      if rand <= @strategy.mutation_prob
        bit_mutation_rate = 1.0 / individual.genome.size
        new_individual = individual.mutate(mutation_rate: bit_mutation_rate)
        new_individual.id = @next_id
        @next_id += 1
        new_individual
      else
        individual
      end
    end

    # Возвращаем элитных особей на их места
    elite_individuals.each_with_index do |elite, i|
      @population[i] = elite
    end
  end

  def tournament
    participants = (0..@population.size - 1).to_a.sample(@strategy.tournament_size)
    pairs = participants.shuffle.each_slice(2).to_a.reject{|pair| pair.length < 2}
    pairs.each do |pair|
      blue = @population[pair[0]]
      red = @population[pair[1]]
      if blue.fitness > red.fitness
        @population[pair[0]] = red
      else
        @population[pair[1]] = blue
      end
    end
  end

  def update_fitness
    @population.each_with_index do |individual, i|
      update_individual_fitness(individual)
    end
  end

  def update_individual_fitness(individual)
    if @cache.key?(individual.id)
      return
    end

    similar = @cache.find do |_, v|
      close_points?(v[:values], individual.values)
    end
    if similar
      individual.fitness = similar[1][:fitness]
      return
    end
    individual.compute_fitness(&@fitness)
    @cache[individual.id] = {fitness: individual.fitness,
                             values: individual.values}
    @total_fitness_runs += 1
  end
  def close_points?(arr1, arr2)
    dist = Math.sqrt(arr1.zip(arr2).map { |a, b| (a - b)**2 }.sum)
    dist < @strategy.epsilon
  end

  def format_values(arr)
    '[' + arr.map { |v| format('%.6e', v) }.join(', ') + ']'
  end

  def tournament_selection
    # Выбираем случайных участников турнира
    tournament_participants = @population.sample(@strategy.tournament_size)
    # Возвращаем лучшего из них
    tournament_participants.min_by(&:fitness)
  end

  private

  def crossover_pair(parent1, parent2)
    if parent1 == parent2
      return nil
    end
    kid1 = parent1.dup
    kid1.id = @next_id
    @next_id += 1

    kid2 = parent2.dup
    kid2.id = @next_id
    @next_id += 1

    point = rand(parent1.genome.size)

    g1 = parent1.genome[0...point] + parent2.genome[point..-1]
    g2 = parent2.genome[0...point] + parent1.genome[point..-1]
    kid1.genome = g1
    kid2.genome = g2
    kid1.values = kid1.decode
    kid2.values = kid2.decode

    [kid1, kid2]
  end

end
