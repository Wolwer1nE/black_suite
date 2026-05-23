# frozen_string_literal: true

require 'set'
require 'json'
require 'time'
require_relative 'mesh_loader'
require_relative 'displacement_visualization_payload'

# Шаг сглаживания поверхности для shape optimization.
# Идея: берём лапласиан по соседним поверхностным узлам, но двигаем узел
# только вдоль его нормали. Это позволяет делать дешёвый «предсглаживающий» шаг
# между дорогими решениями прямой задачи.
#
# Основа:
# - Laplacian smoothing: x_i <- average(neighbors) - x_i
# - ограничение движения вдоль нормали: delta_i = n_i * dot(laplacian_i, n_i)
# - optional Taubin-style second pass (mu < 0) для уменьшения усадки поверхности.
class NormalProjectedSurfaceSmoother
  LEGACY_MODE = :legacy
  AGGRESSIVE_MODE = :aggressive
  DEFAULT_MODE = LEGACY_MODE
  DEFAULT_LAMBDA = 0.35
  DEFAULT_MU = -0.37
  DEFAULT_MAX_STEP = nil
  DEFAULT_OUTPUT_FILENAME = 'smoothing_displacements.json'
  AGGRESSIVE_OUTPUT_FILENAME = 'aggressive_smoothing_displacements.json'
  DEFAULT_RELATIVE_MAX_STEP = 0.015
  DEFAULT_TANGENTIAL_WEIGHT = 0.65
  DEFAULT_TANGENTIAL_LIMIT_RATIO = 0.7

  attr_reader :mesh, :movable_node_ids, :surface_neighbors

  def self.load(mesh_path, normals_path:, movable_node_ids: nil)
    mesh = Mesh.load_from_nas(mesh_path)
    mesh.load_normals!(normals_path)
    new(mesh, movable_node_ids: movable_node_ids)
  end

  def self.normalize_mode(mode)
    normalized = mode.to_s.strip.downcase
    return DEFAULT_MODE if normalized.empty?

    case normalized
    when 'legacy', 'old', 'projected', 'normal'
      LEGACY_MODE
    when 'aggressive', 'blended', 'new'
      AGGRESSIVE_MODE
    else
      raise ArgumentError, "Unknown smoothing mode: #{mode.inspect}"
    end
  end

  def self.output_filename_for_mode(mode)
    normalize_mode(mode) == AGGRESSIVE_MODE ? AGGRESSIVE_OUTPUT_FILENAME : DEFAULT_OUTPUT_FILENAME
  end

  def initialize(mesh, movable_node_ids: nil)
    @mesh = mesh
    source_node_ids = movable_node_ids || mesh.normals.keys
    @movable_node_ids = Array(source_node_ids).map(&:to_i).uniq
    @movable_node_set = @movable_node_ids.to_set
    @surface_neighbors = build_surface_neighbors
  end

  # Возвращает новый Mesh после сглаживания, не мутируя исходный объект.
  def smoothed_mesh(iterations: 1, lambda: DEFAULT_LAMBDA, mu: DEFAULT_MU, max_step: DEFAULT_MAX_STEP,
                    mode: DEFAULT_MODE, tangential_weight: DEFAULT_TANGENTIAL_WEIGHT,
                    tangential_limit_ratio: DEFAULT_TANGENTIAL_LIMIT_RATIO)
    result = duplicate_mesh(@mesh)
    smoother = self.class.new(result, movable_node_ids: @movable_node_ids)
    smoother.smooth!(
      iterations: iterations,
      lambda: lambda,
      mu: mu,
      max_step: max_step,
      mode: mode,
      tangential_weight: tangential_weight,
      tangential_limit_ratio: tangential_limit_ratio
    )
    result
  end

  # Мутирует текущую сетку.
  def smooth!(iterations: 1, lambda: DEFAULT_LAMBDA, mu: DEFAULT_MU, max_step: DEFAULT_MAX_STEP,
              mode: DEFAULT_MODE, tangential_weight: DEFAULT_TANGENTIAL_WEIGHT,
              tangential_limit_ratio: DEFAULT_TANGENTIAL_LIMIT_RATIO)
    iterations.times do
      apply_smoothing_pass!(
        lambda,
        max_step: max_step,
        mode: mode,
        tangential_weight: tangential_weight,
        tangential_limit_ratio: tangential_limit_ratio
      )
      next if mu.nil?

      apply_smoothing_pass!(
        mu,
        max_step: max_step,
        mode: mode,
        tangential_weight: tangential_weight,
        tangential_limit_ratio: tangential_limit_ratio
      )
    end
    mesh
  end

  # Считает projected-Laplacian смещения в виде скаляров вдоль нормали.
  # Полезно, если потом хочется конвертировать шаг в shift_coefficients.
  def smoothing_scalars(weight: DEFAULT_LAMBDA, max_step: DEFAULT_MAX_STEP, mode: DEFAULT_MODE,
                        tangential_weight: DEFAULT_TANGENTIAL_WEIGHT,
                        tangential_limit_ratio: DEFAULT_TANGENTIAL_LIMIT_RATIO)
    displacements_for(
      weight,
      max_step: max_step,
      mode: mode,
      tangential_weight: tangential_weight,
      tangential_limit_ratio: tangential_limit_ratio
    ).transform_values do |data|
      data[:scalar]
    end
  end

  # Возвращает коэффициенты в порядке movable_node_ids.
  def smoothing_coefficients(weight: DEFAULT_LAMBDA, max_step: DEFAULT_MAX_STEP, mode: DEFAULT_MODE,
                             tangential_weight: DEFAULT_TANGENTIAL_WEIGHT,
                             tangential_limit_ratio: DEFAULT_TANGENTIAL_LIMIT_RATIO)
    scalars = smoothing_scalars(
      weight: weight,
      max_step: max_step,
      mode: mode,
      tangential_weight: tangential_weight,
      tangential_limit_ratio: tangential_limit_ratio
    )
    @movable_node_ids.map { |node_id| scalars.fetch(node_id, 0.0) }
  end

  def optimization_coefficients(iterations: 1, lambda: DEFAULT_LAMBDA, mu: DEFAULT_MU, max_step: DEFAULT_MAX_STEP,
                                mode: DEFAULT_MODE, tangential_weight: DEFAULT_TANGENTIAL_WEIGHT,
                                tangential_limit_ratio: DEFAULT_TANGENTIAL_LIMIT_RATIO)
    deltas = deltas_after_smoothing(
      iterations: iterations,
      lambda: lambda,
      mu: mu,
      max_step: max_step,
      mode: mode,
      tangential_weight: tangential_weight,
      tangential_limit_ratio: tangential_limit_ratio
    )

    @movable_node_ids.map do |node_id|
      delta = deltas[node_id] || [0.0, 0.0, 0.0]
      normal = normalized_normal(node_id)
      normal ? dot(delta, normal) : 0.0
    end
  end

  def displacement_payload(iterations: 1, lambda: DEFAULT_LAMBDA, mu: DEFAULT_MU, max_step: DEFAULT_MAX_STEP,
                           mode: DEFAULT_MODE, tangential_weight: DEFAULT_TANGENTIAL_WEIGHT,
                           tangential_limit_ratio: DEFAULT_TANGENTIAL_LIMIT_RATIO)
    normalized_mode = self.class.normalize_mode(mode)
    resolved_max_step = resolve_max_step(max_step)
    deltas_by_node_id = deltas_after_smoothing(
      iterations: iterations,
      lambda: lambda,
      mu: mu,
      max_step: max_step,
      mode: normalized_mode,
      tangential_weight: tangential_weight,
      tangential_limit_ratio: tangential_limit_ratio
    )

    DisplacementVisualizationPayload.from_deltas(
      mesh: @mesh,
      deltas_by_node_id: deltas_by_node_id,
      type: normalized_mode == AGGRESSIVE_MODE ? 'aggressive_surface_smoothing' : 'normal_projected_surface_smoothing',
      parameters: {
        iterations: iterations,
        lambda: lambda,
        mu: mu,
        mode: normalized_mode,
        max_step: resolved_max_step,
        requested_max_step: max_step,
        tangential_weight: normalized_mode == AGGRESSIVE_MODE ? tangential_weight : nil,
        tangential_limit_ratio: normalized_mode == AGGRESSIVE_MODE ? tangential_limit_ratio : nil
      },
      stats: {
        characteristic_edge_length: characteristic_edge_length,
        suggested_max_step: suggested_max_step
      }
    )
  end

  def save_displacement_file(path, iterations: 1, lambda: DEFAULT_LAMBDA, mu: DEFAULT_MU, max_step: DEFAULT_MAX_STEP,
                             mode: DEFAULT_MODE, tangential_weight: DEFAULT_TANGENTIAL_WEIGHT,
                             tangential_limit_ratio: DEFAULT_TANGENTIAL_LIMIT_RATIO)
    payload = displacement_payload(
      iterations: iterations,
      lambda: lambda,
      mu: mu,
      max_step: max_step,
      mode: mode,
      tangential_weight: tangential_weight,
      tangential_limit_ratio: tangential_limit_ratio
    )
    DisplacementVisualizationPayload.write(path, payload)
  end

  def characteristic_edge_length
    @characteristic_edge_length ||= begin
      lengths = smoothing_edges.filter_map do |left, right|
        left_coords = @mesh.nodes[left]
        right_coords = @mesh.nodes[right]
        next unless left_coords && right_coords

        distance(left_coords, right_coords)
      end.sort

      lengths.empty? ? 0.0 : lengths[lengths.size / 2]
    end
  end

  def suggested_max_step
    edge_length = characteristic_edge_length
    return 0.0005 if edge_length <= 1e-12

    edge_length * DEFAULT_RELATIVE_MAX_STEP
  end

  private

  def apply_smoothing_pass!(weight, max_step:, mode:, tangential_weight:, tangential_limit_ratio:)
    displacements = displacements_for(
      weight,
      max_step: max_step,
      mode: mode,
      tangential_weight: tangential_weight,
      tangential_limit_ratio: tangential_limit_ratio
    )
    displacements.each do |node_id, data|
      current = @mesh.nodes[node_id]
      delta = data[:delta]
      @mesh.nodes[node_id] = [
        current[0] + delta[0],
        current[1] + delta[1],
        current[2] + delta[2]
      ]
    end
    @mesh
  end

  def deltas_after_smoothing(iterations:, lambda:, mu:, max_step:, mode:, tangential_weight:, tangential_limit_ratio:)
    smoothed = smoothed_mesh(
      iterations: iterations,
      lambda: lambda,
      mu: mu,
      max_step: max_step,
      mode: mode,
      tangential_weight: tangential_weight,
      tangential_limit_ratio: tangential_limit_ratio
    )

    @movable_node_ids.each_with_object({}) do |node_id, acc|
      source_coords = @mesh.nodes[node_id]
      target_coords = smoothed.nodes[node_id]
      next unless source_coords && target_coords

      acc[node_id] = subtract_vectors(target_coords, source_coords)
    end
  end

  def displacements_for(weight, max_step:, mode:, tangential_weight:, tangential_limit_ratio:)
    return {} if weight.nil? || weight.zero?

    normalized_mode = self.class.normalize_mode(mode)
    resolved_max_step = resolve_max_step(max_step)

    @movable_node_ids.each_with_object({}) do |node_id, acc|
      neighbors = @surface_neighbors[node_id]
      next if neighbors.nil? || neighbors.empty?

      current = @mesh.nodes[node_id]
      next unless current

      normal = normalized_normal(node_id)
      next unless normal

      centroid = average_position(neighbors)
      laplacian = [
        centroid[0] - current[0],
        centroid[1] - current[1],
        centroid[2] - current[2]
      ]

      delta = case normalized_mode
              when LEGACY_MODE
                scalar = clamp_scalar(dot(laplacian, normal) * weight, resolved_max_step)
                normal.map { |component| component * scalar }
              when AGGRESSIVE_MODE
                normal_projection = dot(laplacian, normal)
                normal_delta = normal.map { |component| component * clamp_scalar(normal_projection * weight, resolved_max_step) }
                tangent = subtract_vectors(laplacian, normal.map { |component| component * normal_projection })
                tangent_delta = tangent.map { |component| component * weight * tangential_weight }
                tangent_limit = resolved_max_step.nil? ? nil : resolved_max_step * tangential_limit_ratio
                tangent_delta = clamp_vector_magnitude(tangent_delta, tangent_limit)
                clamp_vector_magnitude(add_vectors(normal_delta, tangent_delta), resolved_max_step)
              end

      scalar = dot(delta, normal)

      acc[node_id] = {
        scalar: scalar,
        delta: delta,
        centroid: centroid,
        normal: normal
      }
    end
  end

  def build_surface_neighbors
    neighbors = Hash.new { |hash, key| hash[key] = Set.new }

    smoothing_edges.each do |left, right|
      left_movable = @movable_node_set.include?(left)
      right_movable = @movable_node_set.include?(right)
      next unless left_movable || right_movable

      neighbors[left] << right if left_movable
      neighbors[right] << left if right_movable
    end

    @movable_node_ids.each do |node_id|
      neighbors[node_id] ||= Set.new
    end

    neighbors.transform_values { |set| set.to_a.sort }
  end

  def surface_simplices
    if @mesh.elements.values.any? { |element| element[:type] == :tetrahedron }
      boundary_faces
    else
      @mesh.elements.values
           .select { |element| element[:type] == :triangle }
           .map { |element| element[:nodes] }
    end
  end

  def boundary_faces
    face_counts = Hash.new(0)
    face_nodes = {}

    @mesh.elements.each_value do |element|
      next unless element[:type] == :tetrahedron && element[:nodes].size == 4

      a, b, c, d = element[:nodes]
      [[a, b, c], [a, b, d], [a, c, d], [b, c, d]].each do |face|
        key = face.sort
        face_counts[key] += 1
        face_nodes[key] ||= face
      end
    end

    face_counts.filter_map do |face_key, count|
      face_nodes[face_key] if count == 1
    end
  end

  def smoothing_edges
    simplices = if @mesh.elements.values.any? { |element| element[:type] == :tetrahedron }
                 surface_simplices
               else
                 triangle_simplices
               end

    simplices.each_with_object(Set.new) do |node_ids, edges|
      node_ids.combination(2) do |left, right|
        edges << [left, right].sort
      end
    end.to_a
  end

  def triangle_simplices
    simplices = @mesh.elements.values
                     .select { |element| element[:type] == :triangle }
                     .map { |element| element[:nodes] }

    return simplices unless simplices.empty?

    surface_simplices
  end

  def normalized_normal(node_id)
    vector = @mesh.normals[node_id]
    return nil unless vector

    length = Math.sqrt(dot(vector, vector))
    return nil if length <= 1e-16

    vector.map { |component| component / length }
  end

  def average_position(node_ids)
    sum = [0.0, 0.0, 0.0]
    count = 0

    node_ids.each do |node_id|
      coords = @mesh.nodes[node_id]
      next unless coords

      sum[0] += coords[0]
      sum[1] += coords[1]
      sum[2] += coords[2]
      count += 1
    end

    raise "No valid neighbors to average" if count.zero?

    [sum[0] / count, sum[1] / count, sum[2] / count]
  end

  def add_vectors(left, right)
    left.zip(right).map { |a, b| a + b }
  end

  def subtract_vectors(left, right)
    left.zip(right).map { |a, b| a - b }
  end

  def dot(left, right)
    left.zip(right).sum { |a, b| a * b }
  end

  def vector_norm(vector)
    Math.sqrt(dot(vector, vector))
  end

  def distance(left, right)
    Math.sqrt(left.zip(right).sum { |a, b| (a - b)**2 })
  end

  def resolve_max_step(max_step)
    max_step.nil? ? suggested_max_step : max_step
  end

  def clamp_scalar(value, max_step)
    return value if max_step.nil?

    [[value, max_step].min, -max_step].max
  end

  def clamp_vector_magnitude(vector, max_magnitude)
    return vector if max_magnitude.nil?

    magnitude = vector_norm(vector)
    return vector if magnitude <= max_magnitude || magnitude <= 1e-16

    scale = max_magnitude / magnitude
    vector.map { |component| component * scale }
  end

  def duplicate_mesh(source)
    copy = Mesh.new
    copy.instance_variable_set(:@nodes, source.nodes.transform_values(&:dup))
    copy.instance_variable_set(:@normals, source.normals.transform_values(&:dup))
    copy.instance_variable_set(
      :@elements,
      source.elements.transform_values do |element|
        {
          nodes: element[:nodes].dup,
          centroid: element[:centroid]&.dup,
          neighbors: element[:neighbors].dup,
          body: element[:body],
          type: element[:type]
        }
      end
    )
    copy
  end
end

if __FILE__ == $PROGRAM_NAME
  mesh_path = ARGV[0] || File.join(__dir__, '..', 'data', 'shapes', 'opt_block', 'optimization_block.nas')
  normals_path = ARGV[1] || File.join(__dir__, '..', 'data', 'shapes', 'opt_block', 'normals.txt')

  smoother = NormalProjectedSurfaceSmoother.load(mesh_path, normals_path: normals_path)
  smoothed = smoother.smoothed_mesh(iterations: 3, lambda: 0.25, mu: -0.26, max_step: 0.0005, mode: :aggressive)

  puts "Movable nodes: #{smoother.movable_node_ids.size}"
  sample_node_id = smoother.movable_node_ids.first
  puts "Sample node #{sample_node_id}:"
  puts "  before: #{smoother.mesh.nodes[sample_node_id].inspect}"
  puts "  after:  #{smoothed.nodes[sample_node_id].inspect}"
end
