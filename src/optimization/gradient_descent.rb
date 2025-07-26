require_relative '../problem'
require_relative '../runner'
require 'json'
require 'ostruct' unless defined?(OpenStruct)

class PointWithMemory
  attr_accessor :coords, :gradient, :fitness, :parent, :speed

  def initialize(coords, gradient: 0, parent: nil)
    @coords = coords
    @gradient = gradient
    @fitness = Float::INFINITY
    @parent = parent
    @speed = 1.0
  end

  def signature
    @coords.map { |x| format('%.8f', x) }.join(',')
  end

  def update_fitness!(fitness_value)
    @fitness = fitness_value
  end
end

class GradientDescentOptimizer
  attr_reader :total_fitness_evaluations, :logger

  def initialize(dimension, mins:, maxs:, names:, logger:, work_dir:, comsol_file:,
                 methodcall:, input_file:, output_file:, learning_rate: 0.01,
                 batch_size: 15, max_iterations: 100, tolerance: 1e-6,
                 finite_diff_step: nil, adaptive_lr: true, momentum: 0.9, silent_mode: false)
    @dimension = dimension
    @mins = mins.dup
    @maxs = maxs.dup
    @names = names.dup
    @logger = logger
    @work_dir = work_dir
    @comsol_file = comsol_file
    @methodcall = methodcall
    @input_file = input_file
    @output_file = output_file
    @silent_mode = silent_mode

    # Параметры градиентного спуска
    @learning_rate = learning_rate
    @initial_learning_rate = learning_rate
    @batch_size = batch_size
    @max_iterations = max_iterations
    @tolerance = tolerance

    # Автоматический расчет шага для градиента на основе масштаба параметров
    if finite_diff_step.nil?
      # Используем 5% от среднего диапазона параметров для быстрого старта
      avg_range = @dimension.times.map { |i| @maxs[i] - @mins[i] }.sum / @dimension
      @finite_diff_step = avg_range * 0.05  # Увеличили с 1% до 5%
      @logger&.log("Автоматический шаг градиента: #{format('%.2e', @finite_diff_step)}")
    else
      @finite_diff_step = finite_diff_step
    end

    @adaptive_lr = adaptive_lr
    @momentum = momentum

    # Состояние оптимизации
    @total_fitness_evaluations = 0
    @best_fitness = Float::INFINITY
    @best_point = nil
    @fitness_cache = {}

    # Инициализация COMSOL runner
    @runner = ComsolRunner.new(@comsol_file, @work_dir, 0, @output_file)

    @logger&.log("Инициализирован градиентный спуск:")
    @logger&.log("  Размерность: #{@dimension}")
    @logger&.log("  Границы: #{@mins} - #{@maxs}")
    @logger&.log("  Параметры: #{@names}")
    @logger&.log("  Размер пакета: #{@batch_size}")
    @logger&.log("  Макс. итераций: #{@max_iterations}")
    @logger&.log("  Тихий режим COMSOL: #{@silent_mode ? 'включен' : 'выключен'}")
  end

  # Основной метод оптимизации
  def run(initial_point: nil)
    @logger&.log("Запуск многоточечного градиентного спуска...")

    # Генерируем 16 случайных стартовых точек
    starting_points = []
    16.times do
      starting_points << generate_random_point
    end

    # Добавляем заданную начальную точку, если есть
    if initial_point
      initial_coords = initial_point.is_a?(Array) ? initial_point : initial_point.coords
      starting_points << PointWithMemory.new(initial_coords)
    end

    @logger&.log("Сгенерировано #{starting_points.size} стартовых точек")

    # Оцениваем все стартовые точки пакетом
    @logger&.log("Оценка стартовых точек...")
    starting_fitness = evaluate_batch(starting_points)
    merge_with_fitness(starting_points, starting_fitness)

    @logger&.log("Результаты стартовых точек:")
    starting_points.each_with_index do |point, idx|
      @logger&.log("  #{idx + 1}. #{format_point(point)} → #{format('%.6e', point.fitness)}")
    end

    # Берем топ-4 точки для детального исследования
    best_starting_points = starting_points.first(4)
    @logger&.log("Выбраны 4 лучшие точки для детального исследования")

    # Глобальные лучшие результаты
    @best_point = best_starting_points.first.coords.dup
    @best_fitness = best_starting_points.first.fitness

    # Основной цикл поиска
    iteration = 0
    current_points = best_starting_points

    while iteration < @max_iterations
      iteration += 1
      @logger&.log("\n--- Итерация #{iteration} ---")

      # Генерируем новые точки: для каждой из 4 точек делаем сдвиги
      new_points = search_paths(current_points)

      @logger&.log("Сгенерировано #{new_points.size} новых точек для исследования")

      # Оцениваем все новые точки пакетом
      new_fitness = evaluate_batch(new_points)
      merge_with_fitness(new_points, new_fitness)

      # Комбинируем старые и новые точки, но берем только улучшения
      improved_points = new_points.select { |p| p.fitness < @best_fitness * 1.1 }  # Только близкие к лучшему
      
      if improved_points.any?
        # Есть улучшения - работаем только с ними
        all_points = current_points + improved_points
        all_points.sort_by!(&:fitness)
        current_points = all_points.first(4)
        @logger&.log("Найдено #{improved_points.size} улучшенных точек")
      else
        # Нет улучшений - берем просто лучшие из новых, но увеличиваем скорость
        all_points = current_points + new_points
        all_points.sort_by!(&:fitness)
        current_points = all_points.first(4)
        # Увеличиваем скорость для более агрессивного поиска
        current_points.each { |p| p.speed *= 1.5 if p.speed < 5.0 }
        @logger&.log("Нет улучшений, увеличиваем скорость поиска")
      end

      # Адаптируем скорость точек только для успешных
      adapt_speeds_aggressive(current_points)

      # Обновляем глобально лучшее решение
      iteration_best = current_points.first
      if iteration_best.fitness < @best_fitness
        @best_fitness = iteration_best.fitness
        @best_point = iteration_best.coords.dup
        @logger&.log("✓ Новый глобальный минимум: #{format('%.6e', @best_fitness)}")
      end

      @logger&.log("Топ-4 точки: #{current_points.map(&:fitness).map { |f| format('%.6e', f) }.join(', ')}")
      @logger&.log("Лучшая точка: #{format_point(current_points.first)}")

      # Проверка сходимости
      if current_points.size >= 2
        improvement = (current_points.last.fitness - current_points.first.fitness).abs
        if improvement < @tolerance
          @logger&.log("Сходимость достигнута (малое улучшение)")
          break
        end
      end
    end

    @logger&.log("\n" + '='*80)
    @logger&.log('ФИНАЛЬНЫЙ РЕЗУЛЬТАТ МНОГОТОЧЕЧНОГО ПОИСКА')
    @logger&.log('='*80)
    @logger&.log("Лучшее решение: #{format_point_coords(@best_point)}")
    @logger&.log("Значение функции: #{format('%.6e', @best_fitness)}")
    @logger&.log("Всего вычислений COMSOL: #{@total_fitness_evaluations}")

    # Возвращаем результат в формате, совместимом с генетическим алгоритмом
    OpenStruct.new(
      values: @best_point,
      fitness: @best_fitness,
      iterations: iteration
    )
  end

  private

  def search_paths(best_starting_points)
    results = []
    best_starting_points.each do |point|
      coords_options = []
      point.coords.each_with_index do |coord, idx|
        step = @finite_diff_step * point.speed
        option_plus = coord + step
        option_minus = coord - step

        # Проверяем границы и корректируем если нужно
        option_plus = [@maxs[idx], option_plus].min
        option_minus = [@mins[idx], option_minus].max

        coords_options << [option_minus, option_plus]
      end

      # Генерируем все комбинации координат
      new_coords = coords_options[0].product(*coords_options[1..-1])
      new_coords.each do |coords|
        # Проверяем что точка не выходит за границы
        bounded_coords = coords.map.with_index { |coord, idx|
          [[coord, @mins[idx]].max, @maxs[idx]].min
        }
        results << PointWithMemory.new(bounded_coords, parent: point)
      end
    end
    results
  end

  def merge_with_fitness(points, fitness_values)
    points.each_with_index do |point, idx|
      point.update_fitness!(fitness_values[idx])
    end
    points.sort_by!(&:fitness)
  end

  def adapt_speeds(points)
    # Адаптируем скорость на основе улучшения
    points.each do |point|
      if point.parent
        if point.fitness < point.parent.fitness
          # Улучшение - увеличиваем скорость
          point.speed = [point.parent.speed * 1.1, 3.0].min
        else
          # Ухудшение - уменьшаем скорость
          point.speed = [point.parent.speed * 0.9, 0.1].max
        end
      end
    end
  end

  def adapt_speeds_aggressive(points)
    # Агрессивная адаптация скорости - увеличиваем для всех
    points.each do |point|
      point.speed = [point.speed * 1.5, 5.0].min
    end
  end

  # Генерация случайной начальной точки
  def generate_random_point
    coords = @dimension.times.map do |i|
      @mins[i] + rand * (@maxs[i] - @mins[i])
    end
    PointWithMemory.new(coords)
  end

  # Пакетное вычисление целевой функции
  # @param [Array] points
  def evaluate_batch(points)
    return [] if points.empty?

    @logger&.log("Пакетное вычисление #{points.size} точек...")

    # Проверяем кэш
    results = []
    uncached_points = []
    uncached_indices = []

    points.each_with_index do |point, idx|
      cache_key = point.signature
      if @fitness_cache.key?(cache_key)
        results[idx] = @fitness_cache[cache_key]
      else
        uncached_points << point
        uncached_indices << idx
      end
    end

    # Вычисляем только некэшированные точки
    if uncached_points.any?
      # Создаем пакетный файл параметров в правильном табличном формате
      param_content = []

      # Первая строка - заголовки параметров
      param_content << @names.join(' ')

      # Каждая точка как отдельная строка значений
      uncached_points.each do |point|
        param_content << point.coords.join(' ')
      end

      param_file = File.join(@work_dir, 'batch_params_gradient.txt')
      File.write(param_file, param_content.join("\n"))

      # Выполняем одно пакетное вычисление для всех точек
      @logger&.log("Запуск COMSOL для пакета из #{uncached_points.size} точек...")

      Problem.new.solve_problem(@methodcall, @runner, param_file, silent_mode: @silent_mode)

      # Читаем все результаты из выходного файла
      output_file_path = File.join(@work_dir, @output_file)
      if File.exist?(output_file_path)
        results_text = File.read(output_file_path)
        result_lines = results_text.strip.split("\n")

        # Парсим результаты для каждой точки
        batch_results = result_lines.map {|line| line.split.last.to_f}

        # Если результатов меньше чем точек, дополняем бесконечностями
        while batch_results.size < uncached_points.size
          batch_results << Float::INFINITY
        end

        @logger&.log("Получено #{batch_results.size} результатов из COMSOL")
      else
        @logger&.log('ПРЕДУПРЕЖДЕНИЕ: Выходной файл не найден, используем бесконечности')
        batch_results = Array.new(uncached_points.size, Float::INFINITY)
      end

      # Сохраняем в кэш и печатаем результаты
      uncached_points.each_with_index do |point, batch_idx|
        result_value = batch_results[batch_idx] || Float::INFINITY

        # Сохраняем в кэш
        cache_key = point.signature
        @fitness_cache[cache_key] = result_value

        unless @silent_mode
          point_str = point.coords.map.with_index { |val, i| "#{@names[i]}=#{format('%.6f', val)}" }.join(', ')
          @logger&.log("  Точка #{batch_idx + 1}: #{point_str} → f = #{format('%.6e', result_value)}")
        end
      end

      # Очистка временных файлов после вычисления
      begin
        File.delete(param_file) if File.exist?(param_file)
        output_file_path = File.join(@work_dir, @output_file)
        File.delete(output_file_path) if File.exist?(output_file_path)
        @logger&.log('Временные файлы очищены')
      rescue => e
        @logger&.log("Предупреждение: не удалось удалить временные файлы: #{e.message}")
      end

      # Заполняем результаты
      uncached_indices.each_with_index do |original_idx, batch_idx|
        results[original_idx] = batch_results[batch_idx]
      end

      @total_fitness_evaluations += uncached_points.size
    end

    results
  end

  def format_point(point)
    point.coords.map.with_index { |val, i| "#{@names[i]}=#{format('%.6f', val)}" }.join(', ')
  end

  def format_point_coords(coords)
    coords.map.with_index { |val, i| "#{@names[i]}=#{format('%.6f', val)}" }.join(', ')
  end
end

# Вспомогательный класс для результата (совместимость с генетическим алгоритмом)
require 'ostruct' unless defined?(OpenStruct)
