require_relative "genetics/gen_alg"
require_relative "simple_logger"

# Функция для оптимизации: минимум x^2 + y^2
fitness = proc { |values| ((values[0])**2 + (values[1])**2) }

# Используем элитную стратегию (можно заменить на classic, super_elite или adaptive)
strategy = GeneticStrategy.elite

puts "Используемая стратегия: #{strategy.description}"
puts "Параметры:"
puts "  Популяция: #{strategy.population_size}"
puts "  Итерации: #{strategy.iterations}"
puts "  Кроссовер: #{strategy.crossover_prob}"
puts "  Мутация: #{strategy.mutation_prob}"
puts "  Турнир: #{strategy.tournament_size}"
puts "  Элитизм: #{strategy.elite_count}"
puts

mins = [-10.0, -10.0]
maxs = [10.0, 10.0]
names = ["x", "y"]

logger = SimpleLogger.new

gen_alg = GeneticAlgorithm.new(
  strategy,
  2,
  mins: mins,
  maxs: maxs,
  names: names,
  bits: 32,
  logger: logger,
  seed: 42,
  &fitness
)
best = gen_alg.run
puts "Лучший индивидуум: [#{best.values.map { |v| format('%.6e', v) }.join(', ')}]"
puts "Значение функции: #{format('%.6e', best.compute_fitness(&fitness))}"

