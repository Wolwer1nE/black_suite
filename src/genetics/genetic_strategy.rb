class GeneticStrategy
  attr_accessor :population_size,
                :iterations,
                :crossover_prob,
                :mutation_prob,
                :tournament_size,
                :epsilon,
                :max_stagnant_epochs,
                :elite_count

  def initialize(population_size:,
                 iterations:,
                 crossover_prob:,
                 mutation_prob:,
                 tournament_size:,
                 epsilon: 1e-6,
                 max_stagnant_epochs: 5,
                 elite_count: 2)
    @population_size = population_size
    @iterations = iterations
    @crossover_prob = crossover_prob
    @mutation_prob = mutation_prob
    @tournament_size = tournament_size
    @epsilon = epsilon
    @max_stagnant_epochs = max_stagnant_epochs
    @elite_count = elite_count
  end

  # Классическая стратегия - традиционные параметры ГА
  def self.classic(population_size: 30, iterations: 100)
    new(
      population_size: population_size,
      iterations: iterations,
      crossover_prob: 0.6,           # Умеренная вероятность кроссовера
      mutation_prob: 0.05,           # Низкая вероятность мутации
      tournament_size: 3,            # Небольшой размер турнира
      epsilon: 1e-6,
      max_stagnant_epochs: 10,       # Больше терпения к застою
      elite_count: 1                 # Минимальный элитизм
    )
  end

  # Элитная стратегия - больше элитизма и отбора
  def self.elite(population_size: 50, iterations: 150)
    new(
      population_size: population_size,
      iterations: iterations,
      crossover_prob: 0.8,           # Высокая вероятность кроссовера
      mutation_prob: 0.02,           # Очень низкая мутация для сохранения хороших генов
      tournament_size: 5,            # Больший размер турнира - сильнее отбор
      epsilon: 1e-8,
      max_stagnant_epochs: 15,       # Больше терпения
      elite_count: 5                 # Много элитных особей
    )
  end

  # Супер-элитная стратегия - максимальный элитизм и точность
  def self.super_elite(population_size: 100, iterations: 200)
    new(
      population_size: population_size,
      iterations: iterations,
      crossover_prob: 0.9,           # Очень высокая вероятность кроссовера
      mutation_prob: 0.01,           # Минимальная мутация
      tournament_size: 7,            # Очень жесткий отбор
      epsilon: 1e-10,                # Высокая точность
      max_stagnant_epochs: 25,       # Максимальное терпение
      elite_count: 10                # Много элитных особей
    )
  end

  # Адаптивная стратегия для сложных задач
  def self.adaptive(population_size: 75, iterations: 300)
    new(
      population_size: population_size,
      iterations: iterations,
      crossover_prob: 0.7,           # Сбалансированный кроссовер
      mutation_prob: 0.08,           # Повышенная мутация для разнообразия
      tournament_size: 4,            # Умеренный отбор
      epsilon: 1e-8,
      max_stagnant_epochs: 20,
      elite_count: 3                 # Умеренный элитизм
    )
  end

  def description
    case
    when @elite_count >= 10 && @mutation_prob <= 0.01
      "Супер-элитная стратегия: максимальный элитизм, минимальная мутация"
    when @elite_count >= 5 && @crossover_prob >= 0.8
      "Элитная стратегия: высокий элитизм, активный кроссовер"
    when @mutation_prob >= 0.05 && @elite_count <= 3
      "Адаптивная стратегия: баланс исследования и эксплуатации"
    else
      "Классическая стратегия: традиционные параметры ГА"
    end
  end
end

