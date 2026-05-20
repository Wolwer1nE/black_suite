# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'mesh_loader'

# Конфигурация для оптимизации формы через CMA-ES
# Управляет шаблонами, рабочими каталогами и путями к файлам
class ShapeOptimizationConfig
  attr_reader :mesh_file, :work_dir, :session_name
  attr_reader :shift_boundaries_template, :form_opt_template
  attr_reader :shift_boundary_json, :form_opt_json
  attr_reader :normals_file, :shifts_file, :shift_jam_file
  attr_reader :optimization_displacement_file, :shape_visualization_displacement_file

  # @param mesh_file [String] путь к файлу сетки
  # @param session_name [String, nil] имя сессии (если nil, генерируется автоматически)
  # @param base_data_dir [String] базовая директория для рабочих каталогов
  def initialize(mesh_file:, session_name: nil, base_data_dir: 'data')
    @mesh_file = File.absolute_path(mesh_file)
    @session_name = session_name || generate_session_name
    @base_data_dir = base_data_dir

    # Рабочий каталог для этой задачи
    @work_dir = File.join(@base_data_dir, @session_name)

    # Пути к шаблонам
    @shift_boundaries_template = File.join('templates', 'shift_boundaries.json')
    @form_opt_template = File.join('templates', 'form_opt.json')

    # Пути к файлам в рабочем каталоге
    @shift_boundary_json = File.join(@work_dir, 'shift_boundaries.json')
    @form_opt_json = File.join(@work_dir, 'form_opt.json')
    @shift_jam_file = File.join(@work_dir, 'shift.jam')
    @shifts_file = File.join(@work_dir, 'shifts.txt')
    @normals_file = File.join(@work_dir, 'normals.txt')
    @optimization_displacement_file = File.join(@work_dir, 'optimization_displacements.json')
    @shape_visualization_displacement_file = File.join(File.dirname(@mesh_file), 'optimization_displacements.json')

    validate_mesh_file
  end

  def inferred_model_settings
    @inferred_model_settings ||= begin
      mesh = Mesh.load_from_nas(@mesh_file)
      element_types = mesh.element_types

      if element_types.empty?
        raise 'В сетке не найдено поддерживаемых элементов (CTRIA3/CTETRA).'
      end

      if element_types.size > 1
        raise "Смешанные типы элементов пока не поддерживаются: #{element_types.join(', ')}"
      end

      dimension = mesh.spatial_dimension
      element_type = element_types.first

      {
        dimension: dimension,
        element_type: acli_element_type(element_type),
        element_order: 1,
        variables: dimension >= 3 ? ':ux, :uy, :uz' : ':ux, :uy'
      }
    end
  end

  # Создаёт рабочий каталог
  def create_work_dir
    FileUtils.mkdir_p(@work_dir)
    puts "Создан рабочий каталог: #{@work_dir}"
  end

  # Создаёт shift_boundaries.json из шаблона с подставленным mesh
  # @return [String] путь к созданному файлу
  def create_shift_boundary_config
    template = read_template(@shift_boundaries_template)
    data_model = template['DataShiftBoundaryBS']['DataModel']
    data_model['mesh'] = @mesh_file
    apply_inferred_model_settings!(data_model)

    write_json(@shift_boundary_json, template)
    @shift_boundary_json
  end

  # Создаёт form_opt.json из шаблона с подставленными значениями
  # @param shift_coefficients_file [String] путь к файлу с коэффициентами смещения
  # @param normals_file [String, nil] путь к файлу с нормалями (если nil, используется @normals_file)
  # @return [String] путь к созданному файлу
  def create_form_opt_config(shift_coefficients_file, normals_file = nil)
    template = read_template(@form_opt_template)
    
    data = template['DataFormOptimizationBS']['DataModel']
    data['mesh'] = @mesh_file
    apply_inferred_model_settings!(data)
    
    # Используем абсолютные пути для всех файлов
    template['DataFormOptimizationBS']['shiftCoefficients'] = File.absolute_path(shift_coefficients_file)
    template['DataFormOptimizationBS']['normals'] = File.absolute_path(normals_file || @normals_file)

    write_json(@form_opt_json, template)
    @form_opt_json
  end

  # Генерирует файл с коэффициентами смещения из вектора
  # @param coefficients [Array<Float>] вектор коэффициентов
  # @return [String] путь к созданному файлу
  def generate_shift_coefficients_file(coefficients, iteration: nil)
    filename = iteration ? "shift_coefficients_#{iteration}.txt" : 'shift_coefficients.txt'
    filepath = File.join(@work_dir, filename)
    
    File.open(filepath, 'w') do |file|
      coefficients.each { |coef| file.puts coef }
    end
    
    filepath
  end

  # Читает границы смещений из shifts.txt
  # @return [Hash] { mins: Array<Float>, maxs: Array<Float>, dimension: Integer }
  def read_shifts_boundaries
    unless File.exist?(@shifts_file)
      raise "Файл границ не найден: #{@shifts_file}"
    end

    mins = []
    maxs = []

    File.foreach(@shifts_file) do |line|
      parts = line.strip.split
      next if parts.empty?
      
      # Формат: id min max
      # id игнорируем (parts[0])
      mins << parts[1].to_f
      maxs << parts[2].to_f
    end

    {
      mins: mins,
      maxs: maxs,
      dimension: mins.size
    }
  end

  # Читает значение целевой функции из goals.txt
  # @return [Float] значение целевой функции
  def read_goal_value
    goals_file = File.join(@work_dir, 'goals.txt')
    
    unless File.exist?(goals_file)
      raise "Файл целевой функции не найден: #{goals_file}"
    end

    File.read(goals_file).strip.to_f
  end

  # Проверяет статус выполнения в shift.jam
  # @return [Boolean] true если status == "success" (регистронезависимо)
  def check_shift_jam_status
    unless File.exist?(@shift_jam_file)
      raise "Файл shift.jam не найден: #{@shift_jam_file}"
    end

    jam_data = JSON.parse(File.read(@shift_jam_file))
    status = jam_data.dig('metaData', 'status') || jam_data.dig('metadata', 'status')

    unless status&.downcase == 'success'
      raise "Ошибка выполнения bs-shift-boundary: status = #{status.inspect}"
    end

    true
  end

  # Проверяет существование normals.txt после bs-shift-boundary
  def check_normals_file
    unless File.exist?(@normals_file)
      raise "Файл normals.txt не найден: #{@normals_file}"
    end
    true
  end

  def displacement_export_targets
    [@optimization_displacement_file, @shape_visualization_displacement_file].uniq
  end

  private

  def generate_session_name
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    "shape_opt_#{timestamp}"
  end

  def validate_mesh_file
    unless File.exist?(@mesh_file)
      raise "Файл сетки не найден: #{@mesh_file}"
    end
  end

  def read_template(template_path)
    unless File.exist?(template_path)
      raise "Шаблон не найден: #{template_path}"
    end
    JSON.parse(File.read(template_path))
  end

  def write_json(filepath, data)
    File.open(filepath, 'w') do |file|
      file.write(JSON.pretty_generate(data))
    end
    puts "Создан файл конфигурации: #{filepath}"
  end

  def apply_inferred_model_settings!(data_model)
    settings = inferred_model_settings
    data_model['variables'] = settings[:variables]
    data_model['elementData'] ||= {}
    data_model['elementData']['elementType'] = settings[:element_type]
    data_model['elementData']['elementOrder'] = settings[:element_order]
  end

  def acli_element_type(element_type)
    case element_type
    when :triangle
      ':triangle'
    when :tetrahedron
      ':tetrahedron'
    else
      raise "Неподдерживаемый тип элемента для ACLI: #{element_type.inspect}"
    end
  end
end
