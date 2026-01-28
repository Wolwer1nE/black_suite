# frozen_string_literal: true

require_relative 'shape_optimization_config'

# Извлечение границ смещений через команду acli bs-shift-boundary
class BoundaryShiftExtractor
  attr_reader :config

  # @param config [ShapeOptimizationConfig] конфигурация оптимизации
  def initialize(config)
    @config = config
  end

  # Выполняет извлечение границ смещений
  # @return [Hash] { mins: Array<Float>, maxs: Array<Float>, dimension: Integer }
  def extract
    puts "\n=== Извлечение границ смещений ==="
    
    # 1. Создаём рабочий каталог
    @config.create_work_dir

    # 2. Создаём shift_boundaries.json из шаблона
    shift_config = @config.create_shift_boundary_config

    # 3. Выполняем команду acli bs-shift-boundary
    execute_shift_boundary_command(shift_config)

    # 4. Проверяем статус выполнения
    @config.check_shift_jam_status
    puts "✓ Статус: success"

    # 5. Проверяем создание normals.txt
    @config.check_normals_file
    puts "✓ Файл normals.txt создан"

    # 6. Читаем границы из shifts.txt
    boundaries = @config.read_shifts_boundaries
    puts "✓ Границы извлечены: #{boundaries[:dimension]} переменных"

    boundaries
  end

  private

  def execute_shift_boundary_command(config_file)
    output_file = @config.shift_jam_file
    
    # Используем абсолютные пути
    abs_config_file = File.absolute_path(config_file)
    abs_output_file = File.absolute_path(output_file)
    
    # Команда: acli bs-shift-boundary <config_json> <output_jam>
    command = "acli bs-shift-boundary \"#{abs_config_file}\" \"#{abs_output_file}\""
    
    puts "Выполнение команды:"
    puts "  #{command}"
    puts "Ожидание завершения..."

    # Выполняем в рабочем каталоге для создания файлов там
    Dir.chdir(@config.work_dir) do
      # Запускаем с перенаправлением всех потоков
      pid = spawn(command, 
                  in: 'NUL',
                  out: 'shift_boundary_out.log', 
                  err: 'shift_boundary_err.log')
      Process.wait(pid)
      exit_status = $?.exitstatus
      
      unless exit_status == 0
        raise "Ошибка выполнения команды acli bs-shift-boundary (код: #{exit_status})"
      end
    end

    puts "✓ Команда выполнена успешно"
  end
end
