require_relative "genetics/gen_alg"

class SimpleLogger
  def log(msg)
    puts msg
  end

  def info(msg)
    puts msg
  end
end

# Функция Розенброка: f(x,y) = (a-x)^2 + b(y-x^2)^2
# Глобальный минимум в точке (a,a) = (1,1) со значением f(1,1) = 0
# Стандартные параметры: a = 1, b = 100
fitness = proc do |values|
  x, y = values[0], values[1]  # Возвращаем y обратно
  a = 1.0
  b = 100.0
  (a - x)**2 + b * (y - x**2)**2
end

mins = [-2.0, -1.0]  # Область поиска для функции Розенброка
maxs = [2.0, 3.0]
names = ["x0", "y0"]  # Возвращаем y0

logger = SimpleLogger.new

puts "=" * 80
puts "СРАВНЕНИЕ СТРАТЕГИЙ ГЕНЕТИЧЕСКОГО АЛГОРИТМА"
puts "=" * 80

strategies = [
  { name: "Классическая", strategy: GeneticStrategy.classic },
  { name: "Элитная", strategy: GeneticStrategy.elite },
  { name: "Супер-элитная", strategy: GeneticStrategy.super_elite },
  { name: "Адаптивная", strategy: GeneticStrategy.adaptive }
]

results = []

strategies.each do |config|
  puts "\n" + "-" * 50
  puts "ТЕСТ: #{config[:name]} стратегия"
  puts "Описание: #{config[:strategy].description}"
  puts "-" * 50

  gen_alg = GeneticAlgorithm.new(
    config[:strategy],
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

  result = {
    name: config[:name],
    best_values: best.values,
    best_fitness: best.fitness,
    fitness_evaluations: gen_alg.instance_variable_get(:@total_fitness_runs),
    strategy: config[:strategy]
  }

  results << result

  puts "\nРЕЗУЛЬТАТ:"
  puts "Лучший индивидуум: [#{best.values.map { |v| format('%.6e', v) }.join(', ')}]"
  puts "Значение функции: #{format('%.6e', best.fitness)}"
  puts "Количество вычислений целевой функции: #{result[:fitness_evaluations]}"
end

puts "\n" + "=" * 80
puts "СВОДКА РЕЗУЛЬТАТОВ"
puts "=" * 80

results.sort_by! { |r| r[:best_fitness] }

results.each_with_index do |result, index|
  puts "#{index + 1}. #{result[:name]}:"
  puts "   Функция: #{format('%.6e', result[:best_fitness])}"
  puts "   Точка: [#{result[:best_values].map { |v| format('%.3f', v) }.join(', ')}]"
  puts "   Вычислений ЦФ: #{result[:fitness_evaluations]}"
  puts "   Параметры: pop=#{result[:strategy].population_size}, " +
       "iter=#{result[:strategy].iterations}, " +
       "elite=#{result[:strategy].elite_count}"
  puts
end

puts "Лучший результат: #{results.first[:name]} стратегия"
puts "Теоретический оптимум: f(1,1) = 0 (функция Розенброка)"
puts "\nЭффективность по количеству вычислений:"
best_result = results.first
results.each do |result|
  efficiency = (best_result[:fitness_evaluations].to_f / result[:fitness_evaluations]) * 100
  puts "#{result[:name]}: #{result[:fitness_evaluations]} вычислений (#{format('%.1f', efficiency)}% от лучшего)"
end
