# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'shape_optimization_config'

# Fitness-функция для оптимизации формы
# Вызывает bs-form-opt и читает значение целевой функции
class FormOptimizationFitness
  attr_reader :config, :evaluation_count

  # @param config [ShapeOptimizationConfig] конфигурация оптимизации
  def initialize(config)
    @config = config
    @evaluation_count = 0
  end

  # Вычисляет значение целевой функции для вектора коэффициентов
  # @param coefficients [Array<Float>] вектор коэффициентов смещения
  # @return [Float] значение целевой функции
  def call(coefficients)
    @evaluation_count += 1
    
    puts "\n--- Вычисление ##{@evaluation_count} ---"
    
    # 1. Генерируем файл с коэффициентами
    shift_coef_file = @config.generate_shift_coefficients_file(
      coefficients, 
      iteration: @evaluation_count
    )
    puts "Коэффициенты: [#{coefficients.first(3).map { |v| format('%.6f', v) }.join(', ')}#{coefficients.size > 3 ? ', ...' : ''}]"

    # 2. Создаём копию normals.txt для этого вычисления (избегаем блокировки файла)
    normals_copy = create_normals_copy(@evaluation_count)

    # 3. Создаём form_opt.json с путями к файлам
    form_config = @config.create_form_opt_config(shift_coef_file, normals_copy)

    # 4. Выполняем bs-form-opt
    execute_form_optimization(form_config)

    # 5. Читаем значение целевой функции
    fitness = @config.read_goal_value
    puts "Fitness: #{format('%.6e', fitness)}"

    fitness
  rescue StandardError => e
    puts "Ошибка при вычислении fitness: #{e.message}"
    puts e.backtrace.first(5).join("\n")
    Float::INFINITY
  end

  private

  def create_normals_copy(iteration)
    original_normals = @config.normals_file
    normals_copy = File.join(@config.work_dir, "normals_#{iteration}.txt")
    
    FileUtils.cp(original_normals, normals_copy)
    normals_copy
  end

  def execute_form_optimization(config_file)
    output_jam = File.join(@config.work_dir, "form_opt_#{@evaluation_count}.jam")
    
    # Используем абсолютные пути
    abs_config_file = File.absolute_path(config_file)
    abs_output_jam = File.absolute_path(output_jam)
    
    # Команда: acli bs-form-opt <config_json> <output.jam>
    # goals.txt создаётся автоматически в рабочем каталоге
    command = "acli bs-form-opt \"#{abs_config_file}\" \"#{abs_output_jam}\""
    
    # Выполняем в рабочем каталоге
    Dir.chdir(@config.work_dir) do
      # Запускаем с перенаправлением всех потоков
      out_log = 'form_opt_out.log'
      err_log = 'form_opt_err.log'
      
      pid = spawn(command, 
                  in: 'NUL',
                  out: out_log, 
                  err: err_log)
      Process.wait(pid)
      exit_status = $?.exitstatus
      
      if exit_status.nil? || exit_status != 0
        # Читаем логи для диагностики
        err_content = File.exist?(err_log) ? File.read(err_log).lines.first(10).join : 'лог пуст'
        raise "Ошибка выполнения acli bs-form-opt (код: #{exit_status.inspect})\nЛог ошибок:\n#{err_content}"
      end
    end

    # Проверяем статус в output.jam
    check_form_opt_status(output_jam)
    
    output_jam
  end

  def check_form_opt_status(jam_file)
    unless File.exist?(jam_file)
      raise "Файл #{jam_file} не найден"
    end

    jam_data = JSON.parse(File.read(jam_file))
    status = jam_data.dig('metaData', 'status') || jam_data.dig('metadata', 'status')

    unless status&.downcase == 'success'
      raise "Ошибка выполнения bs-form-opt: status = #{status.inspect}"
    end
  end
end
