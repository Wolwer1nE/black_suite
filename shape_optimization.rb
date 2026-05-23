#!/usr/bin/env ruby
# frozen_string_literal: true

# Оптимизация формы МКЭ через CMA-ES
# Использование: ruby shape_optimization.rb <mesh_file> [options]

require_relative 'src/shape_optimization_config'
require_relative 'src/boundary_shift_extractor'
require_relative 'src/form_optimization_fitness'
require_relative 'src/parallel_form_optimization_fitness'
require_relative 'src/optimization/cma_es'
require_relative 'src/simple_logger'
require_relative 'src/mesh_loader'
require_relative 'src/displacement_visualization_payload'
require_relative 'src/surface_smoother'

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
  puts "  --workers INT      Количество параллельных процессов acli (по умолчанию: 8)"
  puts "  --pre-smoothing MODE  Инициализация от сглаживания: none|legacy|aggressive (по умолчанию: none)"
  puts "  --smooth-iterations INT  Итерации предсглаживания (по умолчанию: 1)"
  puts "  --smooth-lambda FLOAT    λ для предсглаживания (по умолчанию: 0.25)"
  puts "  --smooth-mu FLOAT        μ для предсглаживания (по умолчанию: -0.26)"
  puts "  --smooth-max-step FLOAT  max step для предсглаживания (по умолчанию: auto)"
  puts "  --no-parallel      Отключить параллельное выполнение"
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
    target_fitness: nil,
    workers: 8,
    parallel: true,
    pre_smoothing: 'none',
    smooth_iterations: 1,
    smooth_lambda: 0.25,
    smooth_mu: -0.26,
    smooth_max_step: nil
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
    when '--workers'
      options[:workers] = args[i + 1].to_i
      i += 2
    when '--pre-smoothing'
      options[:pre_smoothing] = args[i + 1].to_s
      i += 2
    when '--smooth-iterations'
      options[:smooth_iterations] = args[i + 1].to_i
      i += 2
    when '--smooth-lambda'
      options[:smooth_lambda] = args[i + 1].to_f
      i += 2
    when '--smooth-mu'
      options[:smooth_mu] = args[i + 1].to_f
      i += 2
    when '--smooth-max-step'
      options[:smooth_max_step] = args[i + 1].to_f
      i += 2
    when '--no-parallel'
      options[:parallel] = false
      i += 1
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
  puts "Параллелизация:"
  puts "  enabled: #{options[:parallel]}"
  puts "  workers: #{options[:workers]}" if options[:parallel]
  puts "Предсглаживание:"
  puts "  mode: #{options[:pre_smoothing]}"
  if options[:pre_smoothing] != 'none'
    puts "  iterations: #{options[:smooth_iterations]}"
    puts "  lambda: #{options[:smooth_lambda]}"
    puts "  mu: #{options[:smooth_mu].nil? ? 'none' : options[:smooth_mu]}"
    puts "  max_step: #{options[:smooth_max_step] || 'auto'}"
  end
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

  initial_solution = build_pre_smoothing_initial_solution(config, boundaries, options)

  # 3. Инициализация fitness-функции
  if options[:parallel]
    fitness = ParallelFormOptimizationFitness.new(config, max_workers: options[:workers])
    puts "\nИспользуется параллельная оценка fitness (#{options[:workers]} потоков)"
  else
    fitness = FormOptimizationFitness.new(config)
    puts "\nИспользуется последовательная оценка fitness"
  end

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
    seed: nil,  # можно добавить опцию --seed для воспроизводимости
    initial_solution: initial_solution
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

  export_visualization_displacements(config, result, options, elapsed)

  puts "  Рабочий каталог: #{config.work_dir}"
  puts "\nГотово!"
end

def build_pre_smoothing_initial_solution(config, boundaries, options)
  mode = options[:pre_smoothing].to_s
  return nil if mode == 'none'

  mesh = Mesh.load_from_nas(config.mesh_file)
  mesh.load_normals!(config.normals_file)
  ordered_node_ids = mesh.normals.keys.map(&:to_i)
  smoother = SurfaceSmoother.build(mesh, movable_node_ids: ordered_node_ids)
  normalized_mode = SurfaceSmoother.normalize_mode(mode)

  coefficients = smoother.optimization_coefficients(
    iterations: options[:smooth_iterations],
    lambda: options[:smooth_lambda],
    mu: options[:smooth_mu],
    max_step: options[:smooth_max_step],
    mode: normalized_mode
  )

  raise 'Размерность smoothing-инициализации не совпадает с boundaries.' unless coefficients.size == boundaries[:dimension]

  clamped = coefficients.each_with_index.map do |value, index|
    [[value, boundaries[:maxs][index]].min, boundaries[:mins][index]].max
  end

  puts "Начальная точка от #{mode} smoothing подготовлена (#{clamped.size} коэффициентов)."
  clamped
end

def export_visualization_displacements(config, result, options, elapsed)
  mesh = Mesh.load_from_nas(config.mesh_file)
  mesh.load_normals!(config.normals_file)

  ordered_node_ids = mesh.normals.keys.map(&:to_i)
  coefficients = result[:solution].to_a

  payload = DisplacementVisualizationPayload.from_scalars(
    mesh: mesh,
    node_ids: ordered_node_ids,
    scalars: coefficients,
    type: 'shape_optimization_result',
    parameters: {
      source: 'cma_es',
      sigma: options[:sigma],
      generations: result[:generations],
      evaluations: result[:evaluations],
      best_fitness: result[:fitness],
      elapsed_seconds: elapsed,
      pre_smoothing_mode: options[:pre_smoothing]
    },
    stats: {
      coefficients_count: coefficients.size,
      min_coefficient: coefficients.min,
      max_coefficient: coefficients.max
    },
    metadata: {
      mesh_file: config.mesh_file,
      normals_file: config.normals_file,
      session_name: config.session_name
    }
  )

  config.displacement_export_targets.each do |path|
    begin
      DisplacementVisualizationPayload.write(path, payload)
      puts "  Displacement JSON: #{path}"
    rescue StandardError => e
      puts "  ⚠ Не удалось сохранить displacement JSON в #{path}: #{e.message}"
    end
  end
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
