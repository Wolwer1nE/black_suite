require 'json'
require_relative '../../src/mesh_loader'
require_relative '../../src/surface_smoother'

class ShapeRepository
  DISPLACEMENT_FILENAME = SurfaceSmoother::DEFAULT_OUTPUT_FILENAME
  DISPLACEMENT_GLOB = '*_displacements.json'

  def initialize(root_dir)
    @root_dir = File.expand_path(root_dir)
  end

  def scan_shapes
    shape_entries.map do |entry|
      mesh = load_mesh(entry)
      build_summary(entry, mesh)
    end
  end

  def load_shape(shape_id, displacement_file: nil)
    entry = find_shape_entry(shape_id)
    return nil unless entry

    entry = with_selected_displacement(entry, displacement_file)

    mesh = load_mesh(entry)
    build_payload(entry, mesh)
  end

  def shape_entry(shape_id)
    find_shape_entry(shape_id)
  end

  def optimization_support(shape_id)
    entry = find_shape_entry(shape_id)
    return nil unless entry

    mesh = load_mesh(entry)
    optimization_support_for(entry, mesh)
  end

  def generate_displacements(shape_id, iterations:, lambda:, mu:, max_step:, mode: 'legacy')
    entry = find_shape_entry(shape_id)
    return nil unless entry

    raise 'Для этой фигуры не найден файл нормалей.' unless entry[:normals_path]

    smoother = SurfaceSmoother.load(entry[:mesh_path], normals_path: entry[:normals_path])
    requested_max_step = max_step
    effective_max_step = requested_max_step.nil? ? smoother.suggested_max_step : requested_max_step
    normalized_mode = SurfaceSmoother.normalize_mode(mode)

    generated_path = displacement_file_path(entry, mode: normalized_mode)

    smoother.save_displacement_file(
      generated_path,
      iterations: iterations,
      lambda: lambda,
      mu: mu,
      max_step: effective_max_step,
      mode: normalized_mode
    )

    mesh = load_mesh(entry)
    build_payload(refresh_entry(entry).merge(displacement_path: generated_path), mesh)
  end

  private

  def shape_entries
    return [] unless Dir.exist?(@root_dir)

    Dir.children(@root_dir).sort.filter_map do |name|
      full_path = File.join(@root_dir, name)
      next unless File.directory?(full_path)

      mesh_path = Dir.glob(File.join(full_path, '*.nas')).sort.first
      next unless mesh_path

      normals_path = Dir.glob(File.join(full_path, '{normal,normals}*.txt')).sort.first

      {
        id: name,
        name: name.tr('_', ' '),
        directory: full_path,
        mesh_path: mesh_path,
        normals_path: normals_path,
        displacement_path: detect_displacement_path(full_path),
        displacement_files: detect_displacement_files(full_path)
      }
    end
  end

  def find_shape_entry(shape_id)
    shape_entries.find { |entry| entry[:id] == shape_id }
  end

  def load_mesh(entry)
    mesh = Mesh.load_from_nas(entry[:mesh_path])
    mesh.load_normals!(entry[:normals_path]) if entry[:normals_path]
    mesh
  end

  def build_summary(entry, mesh)
    bounds = mesh.bounds
    body_ids = mesh.elements.values.map { |element| element[:body] }.compact.uniq.sort
    displacement_data = load_displacements(entry[:displacement_path])
    displacement_meta = displacement_data && displacement_data[:meta]
    smoothing_stats = smoothing_stats(entry)
    optimization_support = optimization_support_for(entry, mesh)

    {
      id: entry[:id],
      name: entry[:name],
      mesh_file: File.basename(entry[:mesh_path]),
      normals_file: entry[:normals_path] && File.basename(entry[:normals_path]),
      displacement_file: entry[:displacement_path] && File.basename(entry[:displacement_path]),
      displacement_files: Array(entry[:displacement_files]).map { |path| File.basename(path) },
      has_displacements: !!entry[:displacement_path],
      displacement_count: displacement_data ? displacement_data[:displacements].size : 0,
      displacement_parameters: displacement_meta && displacement_meta[:parameters],
      displacement_type: displacement_meta && displacement_meta[:type],
      smoothing_stats: smoothing_stats,
      nodes_count: mesh.nodes.size,
      elements_count: mesh.elements.size,
      normals_count: mesh.normals.size,
      bodies_count: body_ids.size,
      bodies: body_ids,
      dimension: mesh.spatial_dimension,
      element_types: mesh.element_types,
      bounds: bounds,
      optimization_supported: optimization_support[:supported],
      optimization_support_reason: optimization_support[:reason]
    }
  end

  def build_payload(entry, mesh)
    summary = build_summary(entry, mesh)
    displacement_data = load_displacements(entry[:displacement_path])

    summary.merge(
      nodes: mesh.nodes.sort_by { |id, _| id }.map do |id, coords|
        { id: id, coords: coords }
      end,
      elements: mesh.elements.sort_by { |id, _| id }.map do |id, element|
        {
          id: id,
          body: element[:body],
          type: element[:type],
          node_ids: element[:nodes],
          centroid: element[:centroid],
          neighbors: element[:neighbors]
        }
      end,
      normals: mesh.normals.sort_by { |id, _| id }.filter_map do |node_id, vector|
        coords = mesh.nodes[node_id]
        next unless coords

        {
          node_id: node_id,
          coords: coords,
          vector: vector
        }
      end,
      displacement_meta: displacement_data && displacement_data[:meta],
      displacement_stats: displacement_data && displacement_data[:stats],
      displacements: displacement_data ? displacement_data[:displacements] : []
    )
  end

  def smoothing_stats(entry)
    return nil unless entry[:normals_path]

    smoother = SurfaceSmoother.load(entry[:mesh_path], normals_path: entry[:normals_path])
    {
      characteristic_edge_length: smoother.characteristic_edge_length,
      suggested_max_step: smoother.suggested_max_step
    }
  rescue StandardError
    nil
  end

  def optimization_support_for(entry, mesh)
    return unsupported_optimization('Для этой фигуры не найден файл нормалей.') unless entry[:normals_path]

    element_types = mesh.element_types

    if element_types.empty?
      return unsupported_optimization(
        'Shape optimization требует mesh с поддерживаемыми элементами CTRIA3 или CTETRA4.'
      )
    end

    if element_types.size > 1
      return unsupported_optimization(
        "Shape optimization пока не поддерживает смешанные типы элементов: #{element_types.join(', ')}."
      )
    end

    { supported: true, reason: nil }
  end

  def unsupported_optimization(reason)
    { supported: false, reason: reason }
  end

  def detect_displacement_path(directory)
    detect_displacement_files(directory).first
  end

  def detect_displacement_files(directory)
    Dir.glob(File.join(directory, DISPLACEMENT_GLOB))
       .select { |path| File.file?(path) }
       .sort_by { |path| [-File.mtime(path).to_i, File.basename(path)] }
  end

  def displacement_file_path(entry, mode: SurfaceSmoother::LEGACY_MODE)
    filename = SurfaceSmoother.output_filename_for_mode(mode)
    File.join(entry[:directory], filename)
  end

  def refresh_entry(entry)
    entry.merge(
      displacement_path: detect_displacement_path(entry[:directory]),
      displacement_files: detect_displacement_files(entry[:directory])
    )
  end

  def with_selected_displacement(entry, displacement_file)
    filename = displacement_file.to_s.strip
    return entry if filename.empty?

    matching_path = Array(entry[:displacement_files]).find do |path|
      File.basename(path) == filename
    end

    return entry unless matching_path

    entry.merge(displacement_path: matching_path)
  end

  def load_displacements(path)
    return nil unless path && File.exist?(path)

    raw = JSON.parse(File.read(path))
    displacements = Array(raw['displacements']).filter_map do |item|
      node_id = item['node_id']&.to_i
      delta = Array(item['delta']).map(&:to_f)
      next unless node_id && delta.size == 3

      {
        node_id: node_id,
        scalar: item['scalar']&.to_f,
        delta: delta,
        original_coords: Array(item['original_coords']).map(&:to_f),
        smoothed_coords: Array(item['smoothed_coords']).map(&:to_f)
      }
    end

    {
      meta: {
        type: raw['type'],
        version: raw['version'],
        created_at: raw['created_at'],
        movable_nodes_count: raw['movable_nodes_count'],
        parameters: raw['parameters'] || {},
        metadata: raw['metadata'] || {}
      },
      stats: raw['stats'] || {},
      displacements: displacements.sort_by { |item| item[:node_id] }
    }
  end
end
