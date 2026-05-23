# frozen_string_literal: true

require 'set'
require 'json'
require 'time'
require_relative 'mesh_loader'
require_relative 'displacement_visualization_payload'
require_relative 'normal_projected_surface_smoother'

# 2D сглаживание по компонентам связности на границе.
#
# Идея:
# - рассматриваем только граничные рёбра 2D-сетки CTRIA3;
# - выделяем на них узлы с нормалями и строим граф только по этим узлам;
# - находим компоненты связности этого графа;
# - сглаживаем каждую компоненту независимо, не смешивая соседние контуры/дырки.
#
# Двигаются только узлы с нормалями. Узлы без нормалей не двигаются и не участвуют
# в межкомпонентном усреднении.
class BoundaryComponent2DSmoother
    DEFAULT_CORNER_ANGLE_DEGREES = 150.0
  LEGACY_MODE = NormalProjectedSurfaceSmoother::LEGACY_MODE
  AGGRESSIVE_MODE = NormalProjectedSurfaceSmoother::AGGRESSIVE_MODE
  DEFAULT_MODE = NormalProjectedSurfaceSmoother::DEFAULT_MODE
  DEFAULT_LAMBDA = NormalProjectedSurfaceSmoother::DEFAULT_LAMBDA
  DEFAULT_MU = NormalProjectedSurfaceSmoother::DEFAULT_MU
  DEFAULT_MAX_STEP = NormalProjectedSurfaceSmoother::DEFAULT_MAX_STEP
  DEFAULT_OUTPUT_FILENAME = NormalProjectedSurfaceSmoother::DEFAULT_OUTPUT_FILENAME
  AGGRESSIVE_OUTPUT_FILENAME = NormalProjectedSurfaceSmoother::AGGRESSIVE_OUTPUT_FILENAME
  DEFAULT_RELATIVE_MAX_STEP = NormalProjectedSurfaceSmoother::DEFAULT_RELATIVE_MAX_STEP
  DEFAULT_TANGENTIAL_WEIGHT = NormalProjectedSurfaceSmoother::DEFAULT_TANGENTIAL_WEIGHT
  DEFAULT_TANGENTIAL_LIMIT_RATIO = NormalProjectedSurfaceSmoother::DEFAULT_TANGENTIAL_LIMIT_RATIO

  attr_reader :mesh, :movable_node_ids, :surface_neighbors, :boundary_components

  def self.applicable?(mesh)
    element_types = mesh.element_types
    return false if element_types.empty?

    element_types.all? { |type| type == :triangle } && mesh.spatial_dimension <= 2
  end

  def self.load(mesh_path, normals_path:, movable_node_ids: nil)
    mesh = Mesh.load_from_nas(mesh_path)
    mesh.load_normals!(normals_path)
    new(mesh, movable_node_ids: movable_node_ids)
  end

  def self.normalize_mode(mode)
    NormalProjectedSurfaceSmoother.normalize_mode(mode)
  end

  def self.output_filename_for_mode(mode)
    NormalProjectedSurfaceSmoother.output_filename_for_mode(mode)
  end

  def initialize(mesh, movable_node_ids: nil)
    raise ArgumentError, 'BoundaryComponent2DSmoother supports only 2D triangle meshes.' unless self.class.applicable?(mesh)

    @mesh = mesh
    source_node_ids = movable_node_ids || mesh.normals.keys
    @movable_node_ids = Array(source_node_ids).map(&:to_i).uniq.sort
    @movable_node_set = @movable_node_ids.to_set
    @boundary_edges = detect_boundary_edges
      @boundary_graph = build_boundary_graph
      @boundary_separator_nodes = detect_boundary_separator_nodes
      @boundary_node_components = build_boundary_node_components
      @all_node_graph = build_all_node_graph
    @movable_graph = build_movable_graph
    @component_labels = build_component_labels
    @boundary_components = build_boundary_components
    @surface_neighbors = build_surface_neighbors
  end

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

  def smoothing_scalars(weight: DEFAULT_LAMBDA, max_step: DEFAULT_MAX_STEP, mode: DEFAULT_MODE,
                        tangential_weight: DEFAULT_TANGENTIAL_WEIGHT,
                        tangential_limit_ratio: DEFAULT_TANGENTIAL_LIMIT_RATIO)
    displacements_for(
      weight,
      max_step: max_step,
      mode: mode,
      tangential_weight: tangential_weight,
      tangential_limit_ratio: tangential_limit_ratio
    ).transform_values { |data| data[:scalar] }
  end

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
      type: normalized_mode == AGGRESSIVE_MODE ? 'aggressive_boundary_component_2d_smoothing' : 'boundary_component_2d_smoothing',
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
        suggested_max_step: suggested_max_step,
        boundary_components_count: @boundary_components.size,
        boundary_component_sizes: @boundary_components.map(&:size)
      },
      metadata: {
        smoother: 'boundary_component_2d'
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
      lengths = active_smoothing_edges.filter_map do |left, right|
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

      acc[node_id] = {
        scalar: dot(delta, normal),
        delta: delta,
        centroid: centroid,
        normal: normal
      }
    end
  end

  def detect_boundary_edges
    edge_counts = Hash.new(0)
    edge_nodes = {}
    @boundary_edge_incident_nodes = Hash.new { |hash, key| hash[key] = Set.new }

    @mesh.elements.each_value do |element|
      next unless element[:type] == :triangle && element[:nodes].size == 3

      element[:nodes].combination(2) do |left, right|
        key = [left, right].sort
        edge_counts[key] += 1
        edge_nodes[key] ||= key
        element[:nodes].each { |node_id| @boundary_edge_incident_nodes[key] << node_id }
      end
    end

    edge_counts.filter_map do |edge_key, count|
      edge_nodes[edge_key] if count == 1
    end.sort
  end

    def build_boundary_graph
      graph = Hash.new { |hash, key| hash[key] = Set.new }

      @boundary_edges.each do |left, right|
        graph[left] << right
        graph[right] << left
      end

      graph
  end

    def detect_boundary_separator_nodes
      @boundary_graph.each_with_object(Set.new) do |(node_id, neighbors), separators|
        if neighbors.size != 2
          separators << node_id
          next
        end

        separators << node_id if boundary_turn_angle_degrees(node_id, neighbors.to_a) < DEFAULT_CORNER_ANGLE_DEGREES
    end
    end

    def build_boundary_node_components
      return connected_components(@boundary_graph) if @boundary_separator_nodes.empty?

      reduced_graph = Hash.new { |hash, key| hash[key] = Set.new }

      @boundary_graph.each do |node_id, neighbors|
        next if @boundary_separator_nodes.include?(node_id)

        neighbors.each do |neighbor_id|
          next if @boundary_separator_nodes.include?(neighbor_id)

          reduced_graph[node_id] << neighbor_id
      end
      end

      components = connected_components(reduced_graph)
      component_sets = components.map(&:to_set)

      @boundary_separator_nodes.each do |separator_node_id|
        neighbor_component_indexes = component_sets.each_with_index.filter_map do |component_set, index|
          index if @boundary_graph[separator_node_id].any? { |neighbor_id| component_set.include?(neighbor_id) }
        end

        if neighbor_component_indexes.empty?
          components << [separator_node_id]
          component_sets << Set[separator_node_id]
          next
        end

        neighbor_component_indexes.each do |component_index|
          components[component_index] << separator_node_id
          component_sets[component_index] << separator_node_id
      end
      end

      components.map(&:uniq).map(&:sort)
    end

    def connected_components(graph)
      components = []
      visited = Set.new

      graph.keys.sort.each do |start_node_id|
        next if visited.include?(start_node_id)

        queue = [start_node_id]
        visited << start_node_id
        component = []

        until queue.empty?
          node_id = queue.shift
          component << node_id

          graph[node_id].each do |neighbor_id|
            next if visited.include?(neighbor_id)

            visited << neighbor_id
            queue << neighbor_id
        end
        end

        components << component.sort
      end

      components
    end

    def build_all_node_graph
      graph = Hash.new { |hash, key| hash[key] = Set.new }

      @mesh.elements.each_value do |element|
        next unless element[:type] == :triangle && element[:nodes].size == 3

        element[:nodes].combination(2) do |left, right|
          graph[left] << right
          graph[right] << left
        end
      end

      graph
    end

  def build_movable_graph
    graph = Hash.new { |hash, key| hash[key] = Set.new }

    @movable_node_ids.each do |node_id|
      graph[node_id] ||= Set.new
    end

    @mesh.elements.each_value do |element|
      next unless element[:type] == :triangle && element[:nodes].size == 3

      element[:nodes].combination(2) do |left, right|
        next unless @movable_node_set.include?(left) && @movable_node_set.include?(right)

        graph[left] << right
        graph[right] << left
      end
    end

    graph
  end

  def build_boundary_components
    @movable_node_ids.group_by { |node_id| @component_labels[node_id] }
                     .sort_by { |label, _| label }
                     .map { |_label, node_ids| node_ids.sort }
  end

  def build_component_labels
    labels = {}
    queue = []

    seed_nodes_by_component.each do |component_index, seed_nodes|
      seed_nodes.each do |node_id|
        next if labels.key?(node_id)

        labels[node_id] = component_index
        queue << [node_id, component_index]
      end
    end

    until queue.empty?
      node_id, component_index = queue.shift

      @movable_graph[node_id].each do |neighbor_id|
        next if labels.key?(neighbor_id)

        labels[neighbor_id] = component_index
        queue << [neighbor_id, component_index]
      end
    end

    next_component_index = @boundary_node_components.size
    @movable_node_ids.each do |start_node_id|
      next if labels.key?(start_node_id)

      component_index = next_component_index
      next_component_index += 1
      queue = [start_node_id]
      labels[start_node_id] = component_index

      until queue.empty?
        node_id = queue.shift

        @movable_graph[node_id].each do |neighbor_id|
          next if labels.key?(neighbor_id)

          labels[neighbor_id] = component_index
          queue << neighbor_id
        end
      end
    end

    labels
  end

  def seed_nodes_by_component
    @seed_nodes_by_component ||= begin
      seeds = Hash.new { |hash, key| hash[key] = Set.new }
      component_sets = @boundary_node_components.map(&:to_set)

      component_sets.each_with_index do |component_set, component_index|
        @boundary_edges.each do |left, right|
          next unless component_set.include?(left) && component_set.include?(right)

          @boundary_edge_incident_nodes[[left, right].sort].each do |node_id|
            seeds[component_index] << node_id if @movable_node_set.include?(node_id)
          end
        end

        next unless seeds[component_index].empty?

        nearest_movable_nodes_for(component_set).each do |node_id|
          seeds[component_index] << node_id
        end
      end

      seeds
    end
  end

  def nearest_movable_nodes_for(boundary_component_set)
    visited = boundary_component_set.each_with_object(Set.new) { |node_id, set| set << node_id }
    queue = boundary_component_set.to_a.map { |node_id| [node_id, 0] }
    found_distance = nil
    found_nodes = Set.new

    until queue.empty?
      node_id, distance = queue.shift
      break if !found_distance.nil? && distance > found_distance

      if @movable_node_set.include?(node_id)
        found_distance ||= distance
        found_nodes << node_id
        next
      end

      @all_node_graph[node_id].each do |neighbor_id|
        next if visited.include?(neighbor_id)

        visited << neighbor_id
        queue << [neighbor_id, distance + 1]
      end
    end

    found_nodes.to_a.sort
  end

  def boundary_turn_angle_degrees(node_id, neighbor_ids)
    left_id, right_id = neighbor_ids
    origin = @mesh.nodes[node_id]
    left = @mesh.nodes[left_id]
    right = @mesh.nodes[right_id]
    return 180.0 unless origin && left && right

    vector_left = [left[0] - origin[0], left[1] - origin[1]]
    vector_right = [right[0] - origin[0], right[1] - origin[1]]
    length_left = Math.sqrt(vector_left[0]**2 + vector_left[1]**2)
    length_right = Math.sqrt(vector_right[0]**2 + vector_right[1]**2)
    return 180.0 if length_left <= 1e-16 || length_right <= 1e-16

    cosine = ((vector_left[0] * vector_right[0]) + (vector_left[1] * vector_right[1])) / (length_left * length_right)
    cosine = [[cosine, 1.0].min, -1.0].max
    Math.acos(cosine) * 180.0 / Math::PI
  end

  def build_surface_neighbors
    neighbors = Hash.new { |hash, key| hash[key] = Set.new }

    @movable_graph.each do |node_id, adjacent_node_ids|
      node_label = @component_labels[node_id]
      adjacent_node_ids.each do |neighbor_id|
        next unless @component_labels[neighbor_id] == node_label

        neighbors[node_id] << neighbor_id
      end
    end

    @movable_node_ids.each do |node_id|
      neighbors[node_id] ||= Set.new
    end

    neighbors.transform_values { |set| set.to_a.sort }
  end

  def active_smoothing_edges
    @active_smoothing_edges ||= @surface_neighbors.each_with_object(Set.new) do |(node_id, neighbor_ids), edges|
      neighbor_ids.each do |neighbor_id|
        edges << [node_id, neighbor_id].sort
      end
    end.to_a
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

    raise 'No valid neighbors to average' if count.zero?

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
