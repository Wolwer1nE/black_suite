# frozen_string_literal: true

require_relative 'mesh_loader'
require_relative 'normal_projected_surface_smoother'
require_relative 'boundary_component_2d_smoother'

class SurfaceSmoother
  LEGACY_MODE = NormalProjectedSurfaceSmoother::LEGACY_MODE
  AGGRESSIVE_MODE = NormalProjectedSurfaceSmoother::AGGRESSIVE_MODE
  DEFAULT_MODE = NormalProjectedSurfaceSmoother::DEFAULT_MODE
  DEFAULT_OUTPUT_FILENAME = NormalProjectedSurfaceSmoother::DEFAULT_OUTPUT_FILENAME
  AGGRESSIVE_OUTPUT_FILENAME = NormalProjectedSurfaceSmoother::AGGRESSIVE_OUTPUT_FILENAME

  def self.load(mesh_path, normals_path:, movable_node_ids: nil)
    mesh = Mesh.load_from_nas(mesh_path)
    mesh.load_normals!(normals_path)
    build(mesh, movable_node_ids: movable_node_ids)
  end

  def self.build(mesh, movable_node_ids: nil)
    smoother_class_for(mesh).new(mesh, movable_node_ids: movable_node_ids)
  end

  def self.smoother_class_for(mesh)
    BoundaryComponent2DSmoother.applicable?(mesh) ? BoundaryComponent2DSmoother : NormalProjectedSurfaceSmoother
  end

  def self.normalize_mode(mode)
    NormalProjectedSurfaceSmoother.normalize_mode(mode)
  end

  def self.output_filename_for_mode(mode)
    NormalProjectedSurfaceSmoother.output_filename_for_mode(mode)
  end
end
