require 'json'
require_relative '../../src/mesh_loader'

class ShapeRepository
  def initialize(root_dir)
    @root_dir = File.expand_path(root_dir)
  end

  def scan_shapes
    shape_entries.map do |entry|
      mesh = load_mesh(entry)
      build_summary(entry, mesh)
    end
  end

  def load_shape(shape_id)
    entry = find_shape_entry(shape_id)
    return nil unless entry

    mesh = load_mesh(entry)
    build_payload(entry, mesh)
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
        normals_path: normals_path
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

    {
      id: entry[:id],
      name: entry[:name],
      mesh_file: File.basename(entry[:mesh_path]),
      normals_file: entry[:normals_path] && File.basename(entry[:normals_path]),
      nodes_count: mesh.nodes.size,
      elements_count: mesh.elements.size,
      normals_count: mesh.normals.size,
      bodies_count: body_ids.size,
      bodies: body_ids,
      dimension: mesh.spatial_dimension,
      element_types: mesh.element_types,
      bounds: bounds
    }
  end

  def build_payload(entry, mesh)
    summary = build_summary(entry, mesh)

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
      end
    )
  end
end
