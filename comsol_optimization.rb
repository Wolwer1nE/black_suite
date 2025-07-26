#!/usr/bin/env ruby

require_relative 'src/optimization_config'
require_relative 'src/genetics/simple_batch_gen_alg'

def main
  if ARGV.empty?
    puts "Использование: ruby comsol_optimization.rb config.json"
    exit 1
  end

  config_file = ARGV[0]

  unless File.exist?(config_file)
    puts "Файл конфигурации не найден: #{config_file}"
    exit 1
  end

  begin
    config = OptimizationConfig.new(config_file)

    # Красивый вывод загруженной конфигурации (убираем условие для отладки)
    print_config_summary(config, config_file)

    case config.method.downcase
    when 'genetic'
      run_genetic_optimization(config)
    when 'gradient'
      run_gradient_optimization(config)
    else
      puts "Неизвестный метод оптимизации: #{config.method}"
      exit 1
    end

  rescue => e
    puts "Ошибка: #{e.message}"
    puts e.backtrace
    exit 1
  end
end

def print_config_summary(config, config_file)
  puts "=" * 60
  puts "🚀 COMSOL OPTIMIZATION SUITE"
  puts "=" * 60
  puts "📁 Конфигурация загружена из: #{File.basename(config_file)}"
  puts "⏰ Время запуска: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
  puts

  strategy = config.create_genetic_strategy

  puts "🧬 ПАРАМЕТРЫ ОПТИМИЗАЦИИ:"
  puts "  Метод:               #{config.method.upcase}"
  puts "  Максимум поколений:  #{config.max_generations}"
  puts "  Размер популяции:    #{strategy.population_size}"
  puts "  Размер батча:        #{config.batch_size}"
  puts "  Вероятность мутации: #{(strategy.mutation_prob * 100).round(1)}%"
  puts "  Вероятность кроссовера: #{(strategy.crossover_prob * 100).round(1)}%"
  puts "  Размер турнира:      #{strategy.tournament_size}"
  puts "  Элитных особей:      #{strategy.elite_count}"
  puts

  puts "🎯 ПАРАМЕТРЫ МОДЕЛИ:"
  puts "  Размерность:         #{config.dimension}D"
  puts "  Параметры:"
  config.parameter_names.each_with_index do |name, i|
    puts "    #{name.ljust(18)} [#{config.parameter_mins[i]}, #{config.parameter_maxs[i]}]"
  end
  puts

  puts "🔧 НАСТРОЙКИ COMSOL:"
  puts "  Файл модели:         #{config.comsol_file}"
  puts "  Рабочая директория:  #{config.work_dir}"
  puts "  Метод вызова:        #{config.method_call}"
  puts "  Тихий режим:         #{config.silent_output? ? 'Да' : 'Нет'}"
  puts

  puts "💾 НАСТРОЙКИ ВЫВОДА:"
  puts "  Файл кэша:           #{config.cache_file}"
  puts "  Показ прогресса:     #{config.print_progress? ? 'Да' : 'Нет'}"
  puts

  puts "📊 СТРАТЕГИЯ ГЕНЕТИЧЕСКОГО АЛГОРИТМА:"
  puts "  #{strategy.description}"
  puts

  puts "=" * 60
  puts "🏁 Начинаем оптимизацию..."
  puts "=" * 60
  puts
end

def run_genetic_optimization(config)
  puts "Запуск генетической оптимизации..." if config.print_progress?

  # Создаем стратегию из конфигурации
  strategy = config.create_genetic_strategy

  ga = SimpleBatchGeneticAlgorithm.new(
    config.parameter_mins,
    config.parameter_maxs,
    config.parameter_names,
    config.comsol_file,
    config.method_call,
    config.cache_file,
    config.work_dir,
    strategy
  )

  best_individual = ga.evolve(config.max_generations)

  if config.print_progress?
    puts "\nОптимизация завершена!"
    puts "Лучший результат сохранен в #{config.cache_file}"
  end
end

def run_gradient_optimization(config)
  puts "Запуск градиентной оптимизации..." if config.print_progress?

  # Здесь будет подключен градиентный спуск когда он будет готов
  puts "Градиентная оптимизация пока не реализована"
  exit 1
end


main
