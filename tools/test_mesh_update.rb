#!/usr/bin/env ruby
# Test script for Mesh.with_updated_bodies and save_to_nas
require_relative '../src/mesh_loader'

NAS_IN = File.expand_path(File.join(__dir__, '..', 'work_dir', 'rod4_with_body.nas'))
NAS_OUT = File.expand_path(File.join(__dir__, '..', 'work_dir', 'rod4_test_out.nas'))
JSON_OUT = File.expand_path(File.join(__dir__, '..', 'work_dir', 'rod4_test_out.json'))

puts "Input NAS: #{NAS_IN}"
mesh = Mesh.load_from_nas(NAS_IN)
puts "Loaded nodes: #{mesh.nodes.size}, elements: #{mesh.elements.size}"

# Assign bodies based on centroid x coordinate: < 0 => 1, >= 0 => 2
new_mesh = mesh.with_updated_bodies do |elem, orig_mesh|
  c = elem[:centroid]
  if c && c[0]
    c[0] < 0.0 ? 1 : 2
  else
    nil
  end
end

puts "Bodies assigned. Sample elements with bodies:"
count_by_body = Hash.new(0)
new_mesh.elements.each do |eid, e|
  count_by_body[e[:body]] += 1 if e[:body]
end
p count_by_body

puts "Saving JSON to #{JSON_OUT} and NAS to #{NAS_OUT}"
new_mesh.save_to_json(JSON_OUT)
new_mesh.save_to_nas(NAS_OUT)
puts "Done"

