# frozen_string_literal: true

require 'json'
require 'time'

# Унифицированный формат displacement JSON для UI.
# Его могут производить как smoothing, так и оптимизация формы.
class DisplacementVisualizationPayload
  SCHEMA_VERSION = 1

  def self.from_scalars(mesh:, node_ids:, scalars:, type:, parameters: {}, stats: {}, metadata: {})
    raise ArgumentError, 'node_ids and scalars sizes mismatch' unless node_ids.size == scalars.size

    displacements = node_ids.each_with_index.filter_map do |node_id, index|
      coords = mesh.nodes[node_id]
      normal = mesh.normals[node_id]
      next unless coords && normal

      unit_normal = normalize_vector(normal)
      next unless unit_normal

      scalar = scalars[index].to_f
      delta = unit_normal.map { |component| component * scalar }

      {
        node_id: node_id,
        scalar: scalar,
        delta: delta,
        original_coords: coords.dup,
        smoothed_coords: [
          coords[0] + delta[0],
          coords[1] + delta[1],
          coords[2] + delta[2]
        ]
      }
    end

    build_payload(
      type: type,
      movable_nodes_count: node_ids.size,
      parameters: parameters,
      stats: stats,
      metadata: metadata,
      displacements: displacements
    )
  end

  def self.from_deltas(mesh:, deltas_by_node_id:, type:, parameters: {}, stats: {}, metadata: {})
    displacements = deltas_by_node_id.sort_by { |node_id, _| node_id }.filter_map do |node_id, delta|
      coords = mesh.nodes[node_id]
      next unless coords

      {
        node_id: node_id,
        scalar: scalar_along_normal(mesh, node_id, delta),
        delta: delta,
        original_coords: coords.dup,
        smoothed_coords: [
          coords[0] + delta[0],
          coords[1] + delta[1],
          coords[2] + delta[2]
        ]
      }
    end

    build_payload(
      type: type,
      movable_nodes_count: deltas_by_node_id.size,
      parameters: parameters,
      stats: stats,
      metadata: metadata,
      displacements: displacements
    )
  end

  def self.write(path, payload)
    File.write(path, JSON.pretty_generate(payload))
    path
  end

  def self.build_payload(type:, movable_nodes_count:, parameters:, stats:, metadata:, displacements:)
    {
      type: type,
      version: SCHEMA_VERSION,
      created_at: Time.now.utc.iso8601,
      movable_nodes_count: movable_nodes_count,
      parameters: parameters,
      stats: stats,
      metadata: metadata,
      displacements: displacements
    }
  end
  private_class_method :build_payload

  def self.normalize_vector(vector)
    length = Math.sqrt(vector.sum { |component| component * component })
    return nil if length <= 1e-16

    vector.map { |component| component / length }
  end
  private_class_method :normalize_vector

  def self.scalar_along_normal(mesh, node_id, delta)
    normal = normalize_vector(mesh.normals[node_id])
    return 0.0 unless normal

    normal.zip(delta).sum { |left, right| left * right }
  end
  private_class_method :scalar_along_normal
end
