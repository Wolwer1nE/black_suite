require_relative '../src/mesh_loader'

# Simple tests for Mesh#save_to_nas
# Exits with non-zero status on failure and prints diagnostics.

def fail(msg)
  puts "FAIL: #{msg}"
  exit 1
end

# Build a minimal mesh with 4 nodes and 1 tetrahedron element
mesh = Mesh.new
mesh.instance_variable_set(:@nodes, {
  1 => [0.0, 0.0, 0.0],
  2 => [1.0, 0.0, 0.0],
  3 => [0.0, 1.0, 0.0],
  4 => [0.0, 0.0, 1.0]
})
mesh.instance_variable_set(:@elements, {
  10 => { nodes: [1,2,3,4], neighbors: [], centroid: [0.25, 0.25, 0.25] }
})

out1 = File.join(__dir__, 'out1.nas')
mesh.save_to_nas(out1)
content1 = File.read(out1)

# Expect GRID lines for nodes 1..4 in ascending order
[1,2,3,4].each do |nid|
  unless content1.include?("GRID, #{nid},")
    fail("missing GRID line for node #{nid} in out1.nas")
  end
end

# Expect CTETRA without PID: "CTETRA, 10, 1, 2, 3, 4"
unless content1.lines.any? { |l| l.strip == "CTETRA, 10, 1, 2, 3, 4" }
  puts "--- out1.nas ---"
  puts content1
  fail("CTETRA line without body not found or malformed in out1.nas")
end

# Now set a body and verify PID is written
mesh.instance_variable_get(:@elements)[10][:body] = 5
out2 = File.join(__dir__, 'out2.nas')
mesh.save_to_nas(out2)
content2 = File.read(out2)

unless content2.lines.any? { |l| l.strip == "CTETRA, 10, 5, 1, 2, 3, 4" }
  puts "--- out2.nas ---"
  puts content2
  fail("CTETRA line with body not found or malformed in out2.nas")
end

puts "PASS: save_to_nas tests passed"
exit 0
