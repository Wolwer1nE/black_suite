#!/usr/bin/env ruby
# frozen_string_literal: true

# Оптимизация формы МКЭ через CMA-ES
# Использование: ruby shape_optimization.rb <mesh_file> [options]

require_relative 'src/shape_optimization_config'
require_relative 'src/boundary_shift_extractor'
require_relative 'src/form_optimization_fitness'
require_relative 'src/optimization/cma_es'
require_relative 'src/simple_logger'

def print_usage
  puts "Использование: ruby shape_optimization.rb <mesh_file> [options]"
  puts ""
  puts "Аргументы:"
  puts "  mesh_file          Путь к файлу сетки"
  puts ""
  puts "Опции:"
  puts "  --session NAME     Имя сессии (по умолчанию: shape_opt_<timestamp>)"
  puts "  --sigma FLOAT      Начальный размер шага CMA-ES (0 < sigma <= 1, по умолчанию: 0.3)"
  puts "  --max-evals INT    Максимум вычислений fitness (по умолчанию: 1000)"
  puts "  --max-gen INT      Максимум поколений (по умолчанию: 500)"
  puts "  --target FLOAT     Целевое значение fitness для остановки"
  puts "  --help             Показать эту справку"
  puts ""
  puts "Пример:"
  puts "  ruby shape_optimization.rb work_dir/meshes/rod4.nas --sigma 0.2 --max-evals 500"
end

def parse_options(args)
  options = {
    mesh_file: nil,
    session_name: nil,
    sigma: 0.3,
    max_evaluations: 1000,
    max_generations: 500,
    target_fitness: nil
  }

  i = 0
  while i < args.size
    case args[i]
    when '--help', '-h'
      print_usage
      exit 0
    when '--session'
      options[:session_name] = args[i + 1]
      i += 2
    when '--sigma'
      options[:sigma] = args[i + 1].to_f
      i += 2
    when '--max-evals'
      options[:max_evaluations] = args[i + 1].to_i
      i += 2
    when '--max-gen'
      options[:max_generations] = args[i + 1].to_i
      i += 2
    when '--target'
      options[:target_fitness] = args[i + 1].to_f
      i += 2
    else
      if options[:mesh_file].nil?
        options[:mesh_file] = args[i]
      else
        puts "Неизвестная опция: #{args[i]}"
        print_usage
        exit 1
      end
      i += 1
    end
  end

  if options[:mesh_file].nil?
    puts "Ошибка: не указан файл сетки"
    print_usage
    exit 1
  end

  options
end

def main
  options = parse_options(ARGV)

  puts "=" * 70
  puts "CMA-ES Оптимизация формы МКЭ"
  puts "=" * 70
  puts "Файл сетки: #{options[:mesh_file]}"
  puts "Сессия: #{options[:session_name] || 'автогенерация'}"
  puts "Параметры CMA-ES:"
  puts "  sigma: #{options[:sigma]}"
  puts "  max_evaluations: #{options[:max_evaluations]}"
  puts "  max_generations: #{options[:max_generations]}"
  puts "  target_fitness: #{options[:target_fitness] || 'не задан'}"
  puts "=" * 70

  # 1. Инициализация конфигурации
  config = ShapeOptimizationConfig.new(
    mesh_file: options[:mesh_file],
    session_name: options[:session_name]
  )

  # 2. Извлечение границ смещений через acli bs-shift-boundary
  extractor = BoundaryShiftExtractor.new(config)
  boundaries = extractor.extract

  puts "\n" + "=" * 70
  puts "Границы смещений извлечены"
  puts "  Размерность: #{boundaries[:dimension]}"
  puts "  Пример границ (первые 3):"
  boundaries[:mins].first(3).each_with_index do |min_val, i|
    max_val = boundaries[:maxs][i]
    puts "    #{i + 1}: [#{format('%.6f', min_val)}, #{format('%.6f', max_val)}]"
  end
  puts "=" * 70

  # 3. Инициализация fitness-функции
  fitness = FormOptimizationFitness.new(config)

  # 4. Создание и запуск CMA-ES
  logger = SimpleLogger.new

  optimizer = CmaEs.new(
    dimension: boundaries[:dimension],
    mins: boundaries[:mins],
    maxs: boundaries[:maxs],
    sigma: options[:sigma],
    max_evaluations: options[:max_evaluations],
    max_generations: options[:max_generations],
    target_fitness: options[:target_fitness],
    logger: logger,
    seed: nil  # можно добавить опцию --seed для воспроизводимости
  )

  puts "\n" + "=" * 70
  puts "Запуск CMA-ES оптимизации"
  puts "=" * 70

  start_time = Time.now
  result = optimizer.run { |x| fitness.call(x) }
  elapsed = Time.now - start_time

  # 5. Вывод результатов
  puts "\n" + "=" * 70
  puts "Оптимизация завершена"
  puts "=" * 70
  puts "Лучшее значение fitness: #{format('%.10e', result[:fitness])}"
  puts "Поколений: #{result[:generations]}"
  puts "Вычислений fitness: #{result[:evaluations]}"
  puts "Время: #{format('%.2f', elapsed)} секунд"
  puts "=" * 70

  # 6. Сохранение результата
  result_file = File.join(config.work_dir, 'optimization_result.txt')
  File.open(result_file, 'w') do |file|
    file.puts "CMA-ES Shape Optimization Result"
    file.puts "================================="
    file.puts "Mesh file: #{options[:mesh_file]}"
    file.puts "Session: #{config.session_name}"
    file.puts "Best fitness: #{result[:fitness]}"
    file.puts "Generations: #{result[:generations]}"
    file.puts "Evaluations: #{result[:evaluations]}"
    file.puts "Time: #{elapsed} seconds"
    file.puts ""
    file.puts "Best solution:"
    result[:solution].to_a.each_with_index do |val, i|
      file.puts "  #{i + 1}: #{val}"
    end
  end

  # Сохранение лучших коэффициентов
  best_coef_file = config.generate_shift_coefficients_file(
    result[:solution].to_a,
    iteration: 'best'
  )

  puts "\nРезультаты сохранены:"
  puts "  Отчёт: #{result_file}"
  puts "  Лучшие коэффициенты: #{best_coef_file}"
  puts "  Рабочий каталог: #{config.work_dir}"
  puts "\nГотово!"
end

if __FILE__ == $PROGRAM_NAME
  begin
    main
  rescue StandardError => e
    puts "\nОШИБКА: #{e.message}"
    puts e.backtrace.first(10).join("\n")
    exit 1
  end
end
