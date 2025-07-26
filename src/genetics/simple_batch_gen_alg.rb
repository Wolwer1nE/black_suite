require_relative 'batch_gen_alg'
require_relative '../problem'
require_relative '../runner'
require_relative '../simple_logger'

class SimpleBatchGeneticAlgorithm < BatchGeneticAlgorithm

  def initialize(mins, maxs, names, comsol_file, method_call, cache_file, work_dir, strategy)
    # Используем существующий SimpleLogger
    require_relative '../utils'
    logger = SimpleLogger.new

    dimension = names.length

    # Инициализируем базовый класс с переданной стратегией
    super(strategy, dimension,
          mins: mins, maxs: maxs, names: names,
          logger: logger,
          input_file: "batch_input.txt",
          comsol_file: comsol_file,
          work_dir: work_dir,
          methodcall: method_call,
          output_file: "demo_out.txt")

    @cache_file = cache_file
    load_cache_from_file
  end


  private

  def setup_comsol_runner
    @logger.log("Настройка COMSOL runner...")

    comsol_path = File.join(@work_dir, @comsol_file)
    unless File.exist?(comsol_path)
      raise "COMSOL файл не найден: #{comsol_path}"
    end
    if File.exist?(File.join(@work_dir, @output_file))
      File.delete(File.join(@work_dir, @output_file))
    end
    # Создаем единственный runner для рабочей директории
    @runner = ComsolRunner.new(@comsol_file, @work_dir, 0,
                               @output_file)

    @logger.log("COMSOL runner настроен для #{@work_dir}")
  end

  def call_external_solver
    @logger.log("Запуск пакетного расчета в COMSOL...")

    # Читаем входные данные
    input_data = []
    File.readlines(@input_file).each_with_index do |line, index|
      next if index == 0 # Пропускаем заголовок
      values = line.strip.split.map(&:to_f)
      input_data << values
    end

    if input_data.empty?
      @logger.log("Нет данных для обработки")
      return
    end

    @logger.log("Обрабатываем #{input_data.size} точек пакетом...")

    begin
      # Создаем единый файл параметров для всех точек
      param_file = create_batch_param_file(input_data)

      # Один вызов COMSOL для всех точек
      results = process_batch_in_comsol(param_file, input_data.size)

      @logger.log("Пакетный расчет COMSOL завершен. Обработано #{results.size} точек")
      if File.exist?(File.join(@work_dir, @output_file))
        File.delete(File.join(@work_dir, @output_file))
      end
      results
    rescue => e
      @logger.log("Ошибка при пакетной обработке: #{e.message}")
      # Создаем файл с ошибочными результатами
      create_error_results(input_data)
    end
  end

  def process_batch_in_comsol(param_file, expected_count)
    problem = Problem.new

    begin
      @logger.log("Запуск COMSOL для пакета из #{expected_count} точек...")
      result = problem.solve_problem(@methodcall, @runner, param_file)

      output_path = File.join(@runner.work_dir, @runner.output_file)

      if File.exist?(output_path)
        # TODO Для разных задач может потребоваться другой формат чтения
        results = File.readlines(output_path).map do |line|
          line.strip.split.last.to_f
        end
        @logger.log("Получено #{results.size} результатов от COMSOL")

        if results.size != expected_count
          @logger.log("ВНИМАНИЕ: Ожидалось #{expected_count} результатов, получено #{results.size}")
        end

        return results
      else
        @logger.log("ОШИБКА: Выходной файл COMSOL не найден: #{output_path}")
        return Array.new(expected_count, 1e12) # Заполняем ошибочными значениями
      end

    ensure
      # Удаляем временный файл параметров
      File.delete(param_file) if File.exist?(param_file)
    end
  end

  def create_batch_param_file(input_data)
    param_file = File.join(@work_dir, "batch_params_all.txt")

    File.open(param_file, 'w') do |file|
      # Записываем заголовок с именами переменных
      file.puts @names.join(' ')

      # Записываем все точки в правильном формате
      input_data.each do |values|
        file.puts values.map { |v| format('%.6f', v) }.join(' ')
      end
    end

    @logger.log("Создан пакетный файл параметров: #{param_file}")
    param_file
  end

  def write_batch_results(input_data, results)
    File.open(@output_file, 'w') do |file|
      input_data.each_with_index do |values, index|
        result_value = results[index] || 1e12 # Если результата нет, используем большое значение
        values_str = values.map { |v| format('%.6f', v) }.join(' ')
        fitness_str = format('%.16e', result_value)
        file.puts "#{values_str} #{fitness_str}"
      end
    end
  end

  def create_error_results(input_data)
    File.open(@output_file, 'w') do |file|
      input_data.each do |values|
        values_str = values.map { |v| format('%.6f', v) }.join(' ')
        file.puts "#{values_str} #{format('%.16e', 1e12)}"
      end
    end
  end

  def save_cache_to_file
    cache_file = File.join(@work_dir, "optimization_cache.json")

    begin
      require 'json'

      cache_data = {
        total_evaluations: @total_fitness_evaluations,
        timestamp: Time.now.strftime("%Y-%m-%d %H:%M:%S"),
        dimension: @dimension,
        names: @names,
        mins: @mins,
        maxs: @maxs,
        comsol_file: @comsol_file,
        methodcall: @methodcall,
        cache: @cache
      }

      File.open(cache_file, 'w') do |file|
        file.write(JSON.pretty_generate(cache_data))
      end

      @logger.log("Кэш сохранен в файл #{cache_file} (#{@cache.size} записей)")
    rescue => e
      @logger.log("Ошибка при сохранении кэша: #{e.message}")
    end
  end

  def load_cache_from_file
    cache_file = File.join(@work_dir, "optimization_cache.json")

    return unless File.exist?(cache_file)

    begin
      require 'json'

      cache_data = JSON.parse(File.read(cache_file))

      # Проверяем совместимость параметров
      if cache_data['dimension'] == @dimension &&
         cache_data['names'] == @names &&
         cache_data['mins'] == @mins &&
         cache_data['maxs'] == @maxs &&
         cache_data['comsol_file'] == @comsol_file &&
         cache_data['methodcall'] == @methodcall

        @cache = cache_data['cache'] || {}
        @logger.log("Загружен кэш из файла #{cache_file} (#{@cache.size} записей)")
        @logger.log("Предыдущий запуск: #{cache_data['timestamp']}, всего вычислений: #{cache_data['total_evaluations']}")
      else
        @logger.log("Кэш не совместим с текущими параметрами COMSOL оптимизации, начинаем с пустого кэша")
      end

    rescue => e
      @logger.log("Ошибка при загрузке кэша: #{e.message}")
    end
  end
end
