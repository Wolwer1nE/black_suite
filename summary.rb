require 'ui/src/shape_repository'
repo = ShapeRepository.new('.')
results = repo.scan_shapes
puts 'id, nodes_count, elements_count, normals_count, element_types'
results.each do |s|
  types = s[:element_types].join('; ')
  puts "#{s[:id]}, #{s[:nodes_count]}, #{s[:elements_count]}, #{s[:normals_count]}, #{types}"
end
