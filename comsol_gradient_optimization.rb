require_relative 'src/optimization/gradient_descent'
require 'json'

class ComsolLogger
  def log(msg)
    puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  end

  def info(msg)
    puts msg
  end
end

# Загрузка конфигурации из файла
config_path = 'gradient_config.json'
begin
  config = JSON.parse(File.read(config_path))

  # Параметры оптимизации из конфига
  mins = config['optimization_parameters']['mins']
  maxs = config['optimization_parameters']['maxs']
  names = config['optimization_parameters']['names']

  # Настройки COMSOL из конфига
  comsol_file = config['comsol_settings']['model_file']
  methodcall = config['comsol_settings']['method_call']
  comsol_generated_file = config['comsol_settings']['output_file']
  input_file = config['comsol_settings']['input_file']
  silent_mode = config['comsol_settings']['silent_mode'] || false

  # Параметры генетического алгоритма из конфига (используем dimension)
  dimension = config['genetic_algorithm']['dimension']

rescue => e
  puts "ОШИБКА: Не удалось загрузить конфигурацию из #{config_path}"
  puts "Сообщение: #{e.message}"
  puts "Создайте файл конфигурации или проверьте его формат."
  exit(1)
end

logger = ComsolLogger.new

puts '=' * 80
puts 'ОПТИМИЗАЦИЯ С COMSOL - ГРАДИЕНТНЫЙ СПУСК'
puts '=' * 80

puts "Конфигурация загружена из: #{config_path}"
puts "Параметры оптимизации:"
puts "  Границы поиска: #{mins} - #{maxs}"
puts "  Имена параметров: #{names}"
puts

# Выбор параметров градиентного спуска
puts 'Доступные стратегии градиентного спуска:'
puts '1. Консервативная (lr=0.001, batch=10, iter=50)'
puts '2. Стандартная (lr=0.01, batch=15, iter=100)'
puts '3. Агрессивная (lr=0.05, batch=20, iter=150)'
puts '4. Точная (lr=0.005, batch=25, iter=200)'

print 'Выберите стратегию (1-4) [по умолчанию 2]: '
# choice = gets.chomp
choice = 1

strategy_params = case choice
when '1'
  { lr: 0.0001, batch: 10, iter: 50, desc: 'Консервативная' }
when '3'
  { lr: 0.005, batch: 20, iter: 150, desc: 'Агрессивная' }
when '4'
  { lr: 0.0005, batch: 25, iter: 200, desc: 'Точная' }
else
  { lr: 0.001, batch: 15, iter: 100, desc: 'Стандартная' }
end

puts "\nВыбрана стратегия: #{strategy_params[:desc]}"
puts 'Параметры:'
puts "  Скорость обучения: #{strategy_params[:lr]}"
puts "  Размер пакета: #{strategy_params[:batch]}"
puts "  Макс. итераций: #{strategy_params[:iter]}"
puts "  Momentum: 0.9"
puts "  Адаптивная скорость: включена"
puts

work_dir = 'D:/code/black_suite/work_dir'

puts 'Настройки COMSOL:'
puts "  Файл модели: #{comsol_file}"
puts "  Рабочая директория: #{work_dir}"
puts "  Метод расчета: #{methodcall}"
puts "  Генерируемый файл: #{comsol_generated_file}"
puts '  Режим: пакетная обработка градиента'
puts

# Проверяем наличие файла модели
model_path = File.join(work_dir, comsol_file)
unless File.exist?(model_path)
  puts "ОШИБКА: Файл модели не найден: #{model_path}"
  puts 'Убедитесь что:'
  puts "1. Файл #{comsol_file} существует в директории #{work_dir}"
  puts '2. У вас есть права доступа к этой директории'
  exit(1)
end

puts "✓ Файл модели найден: #{model_path}"
puts

# Выбор начальной точки
puts 'Выбор начальной точки:'
puts '1. Случайная точка'
puts '2. Центр области поиска'
puts '3. Ввести вручную'

print 'Выберите вариант (1-3) [по умолчанию 2]: '
#start_choice = gets.chomp
start_choice = 1
initial_point = case start_choice
when '1'
  nil  # Случайная точка будет сгенерирована автоматически
when '3'
  puts 'Введите координаты начальной точки:'
  dimension.times.map do |i|
    print "#{names[i]} (#{mins[i]} до #{maxs[i]}): "
    val = 0.0  # В реальности здесь был бы gets.chomp.to_f
    [[mins[i], val].max, maxs[i]].min
  end
else
  # Центр области поиска
  dimension.times.map { |i| (mins[i] + maxs[i]) / 2.0 }
end

if initial_point
  puts "Начальная точка: #{initial_point.map.with_index { |v, i| "#{names[i]}=#{format('%.6f', v)}" }.join(', ')}"
else
  puts "Начальная точка: случайная"
end
puts

print 'Начать оптимизацию? (y/N): '
confirm = 'y'
unless ['y', 'yes'].include?(confirm)
  puts 'Оптимизация отменена.'
  exit(0)
end

puts "\n" + '=' * 80
puts 'ЗАПУСК ГРАДИЕНТНОГО СПУСКА'
puts '=' * 80

start_time = Time.now

begin
  optimizer = GradientDescentOptimizer.new(
    dimension,
    mins: mins,
    maxs: maxs,
    names: names,
    logger: logger,
    work_dir: work_dir,
    comsol_file: comsol_file,
    methodcall: methodcall,
    input_file: input_file,
    output_file: comsol_generated_file,
    learning_rate: strategy_params[:lr],
    batch_size: strategy_params[:batch],
    max_iterations: strategy_params[:iter],
    tolerance: 1e-6,
    finite_diff_step: nil,
    adaptive_lr: true,
    momentum: 0.9,
    silent_mode: silent_mode
  )

  best = optimizer.run(initial_point: initial_point)
  end_time = Time.now

  puts "\n" + '=' * 80
  puts 'РЕЗУЛЬТАТ ОПТИМИЗАЦИИ'
  puts '=' * 80

  puts '✓ Градиентный спуск завершен успешно!'
  puts
  puts 'Лучшее решение:'
  best.values.each_with_index do |value, index|
    puts "  #{names[index]} = #{format('%.6f', value)}"
  end
  puts
  puts "Значение целевой функции: #{format('%.6e', best.fitness)}"
  puts "Итераций выполнено: #{best.iterations}"
  puts "Всего вычислений COMSOL: #{optimizer.total_fitness_evaluations}"
  puts "Время выполнения: #{format('%.1f', end_time - start_time)} секунд"
  puts "Эффективность: #{format('%.2f', optimizer.total_fitness_evaluations.to_f / (end_time - start_time))} вычислений/сек"

  # Сохраняем результат в файл
  result_file = "work_dir/gradient_result_#{Time.now.strftime('%Y%m%d_%H%M%S')}.txt"
  File.open(result_file, 'w') do |file|
    file.puts 'Результат градиентного спуска COMSOL'
    file.puts "Дата: #{Time.now}"
    file.puts "Стратегия: #{strategy_params[:desc]}"
    file.puts "Модель: #{comsol_file}"
    file.puts ''
    file.puts 'Параметры алгоритма:'
    file.puts "Скорость обучения: #{strategy_params[:lr]}"
    file.puts "Размер пакета: #{strategy_params[:batch]}"
    file.puts "Макс. итераций: #{strategy_params[:iter]}"
    file.puts ''
    file.puts 'Лучшее решение:'
    best.values.each_with_index do |value, index|
      file.puts "#{names[index]} = #{format('%.6f', value)}"
    end
    file.puts ''
    file.puts "Целевая функция: #{format('%.6e', best.fitness)}"
    file.puts "Итераций: #{best.iterations}"
    file.puts "Вычислений COMSOL: #{optimizer.total_fitness_evaluations}"
    file.puts "Время: #{format('%.1f', end_time - start_time)} сек"
    file.puts "Эффективность: #{format('%.2f', optimizer.total_fitness_evaluations.to_f / (end_time - start_time))} вычислений/сек"
  end

  puts "Результат сохранен в файл: #{result_file}"

rescue => e
  puts "\n" + '!' * 80
  puts 'ОШИБКА ПРИ ОПТИМИЗАЦИИ'
  puts '!' * 80
  puts "Сообщение: #{e.message}"
  puts 'Трассировка:'
  puts e.backtrace.first(10).join("\n")
  puts
  puts 'Возможные причины:'
  puts '1. COMSOL не установлен или не найден в PATH'
  puts '2. Неправильные настройки файла модели'
  puts '3. Недостаточно прав доступа к рабочей директории'
  puts '4. Ошибка в методе target_function в COMSOL модели'
  puts '5. Численные проблемы с вычислением градиента'
  exit(1)
end
