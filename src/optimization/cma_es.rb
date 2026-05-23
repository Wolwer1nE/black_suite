# frozen_string_literal: true

require 'matrix'

# CMA-ES (Covariance Matrix Adaptation Evolution Strategy)
# Алгоритм оптимизации для непрерывных задач высокой размерности
#
# Основные идеи:
# - Адаптивное обновление ковариационной матрицы для направления поиска
# - Эволюционный путь (evolution path) для ускорения сходимости
# - Автоматическая адаптация шага (step-size adaptation)
#
# Использование:
#   optimizer = CmaEs.new(
#     dimension: 100,
#     mins: Array.new(100, -0.01),
#     maxs: Array.new(100, 0.01),
#     sigma: 0.3,
#     logger: logger
#   )
#   best = optimizer.run { |x| objective_function(x) }
#
class CmaEs
  attr_reader :dimension, :mins, :maxs, :best_solution, :best_fitness
  attr_reader :generation, :evaluations

  # @param dimension [Integer] размерность задачи
  # @param mins [Array<Float>] минимальные значения параметров
  # @param maxs [Array<Float>] максимальные значения параметров
  # @param sigma [Float] начальный размер шага (0 < sigma <= 1, доля от диапазона)
  # @param population_size [Integer, nil] размер популяции (nil = автоподбор)
  # @param max_evaluations [Integer] максимум вычислений fitness
  # @param max_generations [Integer] максимум поколений
  # @param target_fitness [Float, nil] целевое значение fitness для остановки
  # @param logger [Object, nil] логгер с методом puts
  # @param seed [Integer, nil] seed для воспроизводимости
  def initialize(dimension:, mins:, maxs:, sigma: 0.3,
                 population_size: nil, max_evaluations: 10_000, max_generations: 1000,
                 target_fitness: nil, logger: nil, seed: nil, initial_solution: nil)
    @dimension = dimension
    @mins = mins.is_a?(Array) ? Vector[*mins] : mins
    @maxs = maxs.is_a?(Array) ? Vector[*maxs] : maxs
    @logger = logger
    @target_fitness = target_fitness
    @max_evaluations = max_evaluations
    @max_generations = max_generations

    # Инициализация генератора случайных чисел
    @rng = seed ? Random.new(seed) : Random.new

    # Размер популяции: lambda (потомки) и mu (родители)
    @lambda = population_size || default_population_size
    @mu = @lambda / 2

    # Веса для взвешенной рекомбинации
    @weights = compute_weights
    @mu_eff = 1.0 / @weights.map { |w| w * w }.sum

    # Начальное среднее — центр диапазона (нормализованное пространство [0,1])
    @mean = initial_solution ? prepare_initial_mean(initial_solution) : Vector[*Array.new(@dimension, 0.5)]

    # Начальный размер шага
    @sigma = sigma

    # Ковариационная матрица (единичная) и её разложение
    @c = Matrix.identity(@dimension)
    @b = Matrix.identity(@dimension)  # собственные векторы
    @d = Vector[*Array.new(@dimension, 1.0)]  # собственные значения (sqrt)

    # Эволюционные пути
    @p_sigma = Vector[*Array.new(@dimension, 0.0)]  # для адаптации sigma
    @p_c = Vector[*Array.new(@dimension, 0.0)]      # для адаптации C

    # Параметры адаптации
    setup_adaptation_parameters

    # Счётчики
    @generation = 0
    @evaluations = 0
    @best_solution = nil
    @best_fitness = Float::INFINITY

    # Флаг необходимости обновления разложения C
    @eigen_decomposition_outdated = false
  end

  # Запуск оптимизации
  # @yield [Array<Float>] вектор параметров в исходном пространстве
  # @return [Hash] результат оптимизации
  def run(&fitness_function)
    raise ArgumentError, 'Требуется блок fitness-функции' unless block_given?

    @fitness_function = fitness_function

    log("CMA-ES: dimension=#{@dimension}, lambda=#{@lambda}, mu=#{@mu}, sigma=#{@sigma}")

    while continue_optimization?
      @generation += 1

      # 1. Генерация популяции
      population = generate_population

      # 2. Оценка fitness
      fitness_values = evaluate_population(population)

      # 3. Сортировка по fitness (минимизация)
      sorted_indices = fitness_values.each_with_index.sort_by { |f, _| f }.map(&:last)
      sorted_population = sorted_indices.map { |i| population[i] }
      sorted_fitness = sorted_indices.map { |i| fitness_values[i] }

      # 4. Обновление лучшего решения
      if sorted_fitness[0] < @best_fitness
        @best_fitness = sorted_fitness[0]
        @best_solution = denormalize(sorted_population[0])
      end

      # 5. Обновление среднего (взвешенная рекомбинация mu лучших)
      old_mean = @mean
      @mean = weighted_mean(sorted_population.first(@mu))

      # 6. Обновление эволюционных путей и ковариационной матрицы
      update_evolution_paths(old_mean)
      update_covariance_matrix(old_mean, sorted_population.first(@mu))
      update_sigma

      # 7. Обновление разложения C (периодически)
      update_eigen_decomposition if @eigen_decomposition_outdated

      log_generation(sorted_fitness) if @generation % 10 == 0 || @generation == 1
    end

    log("CMA-ES завершён: generations=#{@generation}, evaluations=#{@evaluations}")
    log("Лучший fitness: #{@best_fitness}")

    {
      solution: @best_solution,
      fitness: @best_fitness,
      generations: @generation,
      evaluations: @evaluations
    }
  end

  private

  # Размер популяции по умолчанию (рекомендация Hansen)
  def default_population_size
    (4 + (3 * Math.log(@dimension)).floor).clamp(8, 256)
  end

  # Веса для рекомбинации (логарифмические, нормализованные)
  def compute_weights
    raw_weights = (1..@mu).map { |i| Math.log(@mu + 0.5) - Math.log(i) }
    sum = raw_weights.sum
    raw_weights.map { |w| w / sum }
  end

  # Параметры адаптации по Hansen
  def setup_adaptation_parameters
    n = @dimension.to_f

    # Параметры для адаптации sigma (CSA - Cumulative Step-size Adaptation)
    @c_sigma = (@mu_eff + 2) / (n + @mu_eff + 5)
    @d_sigma = 1 + 2 * [0, Math.sqrt((@mu_eff - 1) / (n + 1)) - 1].max + @c_sigma

    # Параметры для адаптации C
    @c_c = (4 + @mu_eff / n) / (n + 4 + 2 * @mu_eff / n)
    @c_1 = 2 / ((n + 1.3)**2 + @mu_eff)
    @c_mu = [1 - @c_1, 2 * (@mu_eff - 2 + 1 / @mu_eff) / ((n + 2)**2 + @mu_eff)].min

    # Ожидаемая длина случайного вектора ||N(0,I)||
    @chi_n = Math.sqrt(n) * (1 - 1 / (4 * n) + 1 / (21 * n * n))
  end

  # Генерация популяции из многомерного нормального распределения
  def generate_population
    update_eigen_decomposition if @eigen_decomposition_outdated

    Array.new(@lambda) do
      # z ~ N(0, I)
      z = Vector[*Array.new(@dimension) { random_normal }]

      # y = B * D * z (преобразование через разложение C)
      y = transform_z(z)

      # x = mean + sigma * y
      x = @mean + @sigma * y

      # Ограничение в [0, 1]
      Vector[*x.to_a.map { |v| v.clamp(0.0, 1.0) }]
    end
  end

  # Преобразование z через разложение C: y = B * D * z
  def transform_z(z)
    # D — диагональ (вектор), B — матрица собственных векторов
    dz = Vector[*z.each_with_index.map { |zi, i| @d[i] * zi }]
    @b * dz
  end

  # Оценка fitness для популяции
  def evaluate_population(population)
    @evaluations += population.size
    
    # Денормализуем всю популяцию
    denormalized_population = population.map { |ind| denormalize(ind).to_a }
    
    # Проверяем, поддерживает ли fitness-функция пакетную оценку
    if @fitness_function.respond_to?(:evaluate_batch)
      # Используем пакетную оценку (параллельно)
      @fitness_function.evaluate_batch(denormalized_population)
    else
      # Последовательная оценка (обратная совместимость)
      denormalized_population.map { |params| @fitness_function.call(params) }
    end
  end

  # Денормализация из [0,1] в исходное пространство
  def denormalize(normalized)
    Vector[*normalized.each_with_index.map { |v, i| @mins[i] + v * (@maxs[i] - @mins[i]) }]
  end

  # Нормализация из исходного пространства в [0,1]
  def normalize(original)
    Vector[*original.each_with_index.map { |v, i| (v - @mins[i]) / (@maxs[i] - @mins[i]) }]
  end

  def prepare_initial_mean(initial_solution)
    vector = initial_solution.is_a?(Vector) ? initial_solution : Vector[*Array(initial_solution).map(&:to_f)]
    raise ArgumentError, 'initial_solution dimension mismatch' unless vector.size == @dimension

    normalized = normalize(vector)
    Vector[*normalized.to_a.map { |value| value.clamp(0.0, 1.0) }]
  end

  # Взвешенное среднее mu лучших особей
  def weighted_mean(best_individuals)
    result = Vector[*Array.new(@dimension, 0.0)]
    best_individuals.each_with_index do |ind, i|
      result += @weights[i] * ind
    end
    result
  end

  # Обновление эволюционных путей
  def update_evolution_paths(old_mean)
    # Инверсия sqrt(C) через B и D
    # C^(-1/2) = B * D^(-1) * B^T
    delta = @mean - old_mean
    invsqrt_c_delta = inverse_sqrt_c_times(delta / @sigma)

    # p_sigma = (1 - c_sigma) * p_sigma + sqrt(c_sigma * (2 - c_sigma) * mu_eff) * C^(-1/2) * (mean - old_mean) / sigma
    @p_sigma = (1 - @c_sigma) * @p_sigma +
               Math.sqrt(@c_sigma * (2 - @c_sigma) * @mu_eff) * invsqrt_c_delta

    # Определяем h_sigma (heaviside function)
    p_sigma_norm = Math.sqrt(@p_sigma.inner_product(@p_sigma))
    h_sigma_threshold = (1.4 + 2.0 / (@dimension + 1)) * @chi_n *
                        Math.sqrt(1 - (1 - @c_sigma)**(2 * @generation))
    @h_sigma = p_sigma_norm < h_sigma_threshold ? 1 : 0

    # p_c = (1 - c_c) * p_c + h_sigma * sqrt(c_c * (2 - c_c) * mu_eff) * (mean - old_mean) / sigma
    @p_c = (1 - @c_c) * @p_c +
           @h_sigma * Math.sqrt(@c_c * (2 - @c_c) * @mu_eff) * (delta / @sigma)
  end

  # C^(-1/2) * v через разложение: B * D^(-1) * B^T * v
  def inverse_sqrt_c_times(v)
    bt_v = @b.transpose * v
    d_inv_bt_v = Vector[*bt_v.each_with_index.map { |x, i| x / @d[i] }]
    @b * d_inv_bt_v
  end

  # Обновление ковариационной матрицы
  def update_covariance_matrix(old_mean, best_individuals)
    n = @dimension

    # Rank-one update
    delta_hs = (1 - @h_sigma) * @c_c * (2 - @c_c)
    p_c_outer = outer_product(@p_c, @p_c)

    # Rank-mu update
    rank_mu = Matrix.zero(n)
    best_individuals.each_with_index do |ind, i|
      y = (ind - old_mean) / @sigma
      rank_mu += @weights[i] * outer_product(y, y)
    end

    # C = (1 - c_1 - c_mu + delta_hs * c_1) * C + c_1 * p_c * p_c^T + c_mu * rank_mu
    @c = (1 - @c_1 - @c_mu + delta_hs * @c_1) * @c +
         @c_1 * p_c_outer +
         @c_mu * rank_mu

    @eigen_decomposition_outdated = true
  end

  # Внешнее произведение двух векторов
  def outer_product(v1, v2)
    Matrix.build(@dimension) { |i, j| v1[i] * v2[j] }
  end

  # Обновление sigma (step-size adaptation)
  def update_sigma
    p_sigma_norm = Math.sqrt(@p_sigma.inner_product(@p_sigma))
    @sigma *= Math.exp(@c_sigma / @d_sigma * (p_sigma_norm / @chi_n - 1))

    # Ограничение sigma
    @sigma = @sigma.clamp(1e-20, 1e10)
  end

  # Обновление разложения ковариационной матрицы
  def update_eigen_decomposition
    # Симметризация C (на случай численных ошибок)
    @c = (@c + @c.transpose) / 2.0

    # Собственное разложение
    eigen = eigen_decomposition(@c)
    @b = eigen[:vectors]
    @d = Vector[*eigen[:values].map { |v| Math.sqrt([v, 1e-20].max) }]

    @eigen_decomposition_outdated = false
  end

  # Собственное разложение симметричной матрицы (Jacobi method)
  def eigen_decomposition(matrix)
    n = matrix.row_count
    a = matrix.to_a.map(&:dup)
    v = Array.new(n) { |i| Array.new(n) { |j| i == j ? 1.0 : 0.0 } }

    max_iterations = 100
    tolerance = 1e-10

    max_iterations.times do
      # Найти максимальный внедиагональный элемент
      max_val = 0.0
      p_idx = 0
      q_idx = 1

      (0...n).each do |i|
        ((i + 1)...n).each do |j|
          if a[i][j].abs > max_val
            max_val = a[i][j].abs
            p_idx = i
            q_idx = j
          end
        end
      end

      break if max_val < tolerance

      # Вращение Якоби
      jacobi_rotate(a, v, p_idx, q_idx)
    end

    eigenvalues = Array.new(n) { |i| a[i][i] }
    eigenvectors = Matrix[*v].transpose

    { values: eigenvalues, vectors: eigenvectors }
  end

  # Вращение Якоби для собственного разложения
  def jacobi_rotate(a, v, p, q)
    n = a.size
    return if a[p][q].abs < 1e-20

    theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q])
    t = theta.abs > 1e10 ? 1.0 / (2.0 * theta) : 1.0 / (theta.abs + Math.sqrt(1 + theta**2)) * (theta >= 0 ? 1 : -1)

    c = 1.0 / Math.sqrt(1 + t**2)
    s = t * c

    # Обновление A
    a_pp = a[p][p]
    a_qq = a[q][q]
    a[p][p] = c**2 * a_pp - 2 * s * c * a[p][q] + s**2 * a_qq
    a[q][q] = s**2 * a_pp + 2 * s * c * a[p][q] + c**2 * a_qq
    a[p][q] = 0.0
    a[q][p] = 0.0

    (0...n).each do |i|
      next if i == p || i == q

      a_ip = a[i][p]
      a_iq = a[i][q]
      a[i][p] = c * a_ip - s * a_iq
      a[p][i] = a[i][p]
      a[i][q] = s * a_ip + c * a_iq
      a[q][i] = a[i][q]
    end

    # Обновление V (собственные векторы)
    (0...n).each do |i|
      v_ip = v[i][p]
      v_iq = v[i][q]
      v[i][p] = c * v_ip - s * v_iq
      v[i][q] = s * v_ip + c * v_iq
    end
  end

  # Генерация нормально распределенного случайного числа (Box-Muller)
  def random_normal
    u1 = @rng.rand
    u2 = @rng.rand
    Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math::PI * u2)
  end

  # Условие продолжения оптимизации
  def continue_optimization?
    return false if @evaluations >= @max_evaluations
    return false if @generation >= @max_generations
    return false if @target_fitness && @best_fitness <= @target_fitness
    return false if @sigma < 1e-20  # сходимость

    true
  end

  def log(message)
    @logger&.log(message)
  end

  def log_generation(sorted_fitness)
    best = sorted_fitness[0]
    median = sorted_fitness[@lambda / 2]
    worst = sorted_fitness[-1]
    log("Gen #{@generation}: best=#{format('%.6e', best)} median=#{format('%.6e', median)} " \
        "worst=#{format('%.6e', worst)} sigma=#{format('%.4f', @sigma)} evals=#{@evaluations}")
  end
end
