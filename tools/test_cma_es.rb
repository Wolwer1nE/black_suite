# frozen_string_literal: true

# Тест CMA-ES на классических тестовых функциях оптимизации

require_relative '../src/optimization/cma_es'
require_relative '../src/simple_logger'

# Тестовые функции для бенчмаркинга
module TestFunctions
  # Сфера: f(x) = sum(x_i^2), минимум в 0
  def self.sphere(x)
    x.map { |v| v**2 }.sum
  end

  # Функция Растригина: многомодальная, минимум в 0
  def self.rastrigin(x)
    n = x.size
    10 * n + x.map { |xi| xi**2 - 10 * Math.cos(2 * Math::PI * xi) }.sum
  end

  # Функция Розенброка: "банановая долина", минимум в (1, 1, ..., 1)
  def self.rosenbrock(x)
    sum = 0.0
    (0...(x.size - 1)).each do |i|
      sum += 100 * (x[i + 1] - x[i]**2)**2 + (1 - x[i])**2
    end
    sum
  end

  # Функция Экли: многомодальная, минимум в 0
  def self.ackley(x)
    n = x.size
    sum1 = x.map { |xi| xi**2 }.sum
    sum2 = x.map { |xi| Math.cos(2 * Math::PI * xi) }.sum

    -20 * Math.exp(-0.2 * Math.sqrt(sum1 / n)) -
      Math.exp(sum2 / n) + 20 + Math::E
  end
end

def run_test(name, dimension, mins, maxs, target_fitness, &fitness_func)
  puts "\n" + '=' * 60
  puts "Тест: #{name} (#{dimension}D)"
  puts '=' * 60

  logger = SimpleLogger.new

  optimizer = CmaEs.new(
    dimension: dimension,
    mins: mins,
    maxs: maxs,
    sigma: 0.3,
    max_evaluations: 10_000,
    max_generations: 500,
    target_fitness: target_fitness,
    logger: logger,
    seed: 42
  )

  start_time = Time.now
  result = optimizer.run(&fitness_func)
  elapsed = Time.now - start_time

  puts "\nРезультат:"
  puts "  Fitness: #{format('%.10f', result[:fitness])}"
  puts "  Целевой fitness: #{target_fitness || 'не задан'}"
  puts "  Достигнут: #{result[:fitness] <= (target_fitness || Float::INFINITY) ? 'ДА' : 'НЕТ'}"
  puts "  Поколений: #{result[:generations]}"
  puts "  Вычислений fitness: #{result[:evaluations]}"
  puts "  Время: #{format('%.2f', elapsed)} сек"

  if dimension <= 10
    puts "  Решение: [#{result[:solution].to_a.map { |v| format('%.6f', v) }.join(', ')}]"
  else
    puts "  Решение (первые 5): [#{result[:solution].to_a.first(5).map { |v| format('%.6f', v) }.join(', ')}, ...]"
  end

  result
end

puts 'CMA-ES Benchmark Tests'
puts Time.now

# Тест 1: Сфера 10D
run_test('Sphere', 10,
         Array.new(10, -5.0),
         Array.new(10, 5.0),
         1e-8) { |x| TestFunctions.sphere(x) }

# Тест 2: Сфера 50D (высокая размерность)
run_test('Sphere 50D', 50,
         Array.new(50, -5.0),
         Array.new(50, 5.0),
         1e-6) { |x| TestFunctions.sphere(x) }

# Тест 3: Растригин 10D (многомодальная)
run_test('Rastrigin', 10,
         Array.new(10, -5.12),
         Array.new(10, 5.12),
         1e-4) { |x| TestFunctions.rastrigin(x) }

# Тест 4: Розенброк 10D
run_test('Rosenbrock', 10,
         Array.new(10, -5.0),
         Array.new(10, 10.0),
         1e-4) { |x| TestFunctions.rosenbrock(x) }

# Тест 5: Экли 10D
run_test('Ackley', 10,
         Array.new(10, -5.0),
         Array.new(10, 5.0),
         1e-4) { |x| TestFunctions.ackley(x) }

# Тест 6: Узкие диапазоны (имитация смещения узлов МКЭ)
puts "\n" + '=' * 60
puts 'Тест: Узкие диапазоны (имитация МКЭ), 100D'
puts '=' * 60

# У каждого параметра свой диапазон смещения
mins_narrow = Array.new(100) { |i| -0.001 - 0.0001 * (i % 10) }
maxs_narrow = Array.new(100) { |i| 0.001 + 0.0001 * (i % 10) }

run_test('Narrow Ranges', 100,
         mins_narrow,
         maxs_narrow,
         1e-10) { |x| TestFunctions.sphere(x) }

puts "\n" + '=' * 60
puts 'Все тесты завершены'
puts '=' * 60
