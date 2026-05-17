require 'set'
require 'json'

class Mesh
  NUMBER_PATTERN = /[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/

  attr_reader :nodes, :elements, :normals

  def initialize
    @nodes = {}      # id => [x,y,z]
    @elements = {}   # id => { nodes: [nid,...], centroid: [x,y,z], neighbors: [eid,...], type:, body: }
    @normals = {}    # node_id => [nx, ny, nz]
  end

  # Load mesh from a .nas file path
  def self.load_from_nas(path)
    mesh = Mesh.new

    File.foreach(path) do |line|
      line = line.chomp
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?('$')

      case stripped
      when /^GRID\b/i
        numbers = line.scan(NUMBER_PATTERN)
        next if numbers.size < 4

        node_id = numbers[0].to_i
        coords = numbers[1, 3].map(&:to_f)
        mesh.nodes[node_id] = coords
      when /^CTRIA3\b/i
        mesh.parse_element_line(line, :triangle, 3)
      when /^CTETRA\b/i
        mesh.parse_element_line(line, :tetrahedron, 4)
      end
    end

    mesh.finalize!

    mesh
  end

  def self.load_normals(path)
    normals = {}

    File.foreach(path) do |line|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?('$')

      tokens = stripped.split
      next if tokens.size < 4

      node_id = tokens[0].to_i
      normals[node_id] = tokens[1, 3].map(&:to_f)
    end

    normals
  end

  def load_normals!(path)
    @normals = self.class.load_normals(path)
    self
  end

  def finalize!
    @elements.each do |eid, data|
      node_ids = data[:nodes]
      coords = node_ids.map { |nid| @nodes[nid] }
      if coords.any? && coords.all?
        sx = sy = sz = 0.0
        coords.each do |c|
          sx += c[0]
          sy += c[1]
          sz += c[2]
        end
        n = coords.size.to_f
        data[:centroid] = [sx / n, sy / n, sz / n]
      else
        data[:centroid] = nil
        warn "WARN: missing node coordinates for element #{eid}. Node ids: #{node_ids.inspect}"
      end
      data[:neighbors] ||= []
    end

    adjacency_map = Hash.new { |h, k| h[k] = [] }

    @elements.each do |eid, data|
      nodes = data[:nodes]
      side_size = nodes.size - 1
      next if side_size <= 0

      nodes.combination(side_size).each do |face_nodes|
        adjacency_map[face_nodes.sort.join('_')] << eid
      end
    end

    adjacency_map.each_value do |eids|
      next unless eids.size > 1

      eids.each do |eid|
        @elements[eid][:neighbors] |= (eids - [eid])
      end
    end

    self
  end

  def parse_element_line(line, type, node_count)
    ints = line.strip.split.drop(1).map(&:to_i)
    if ints.size < node_count + 1
      warn "WARN: #{type} line has insufficient ints: #{line}"
      return
    end

    elem_id = ints[0]
    body = ints[1] if ints.size >= node_count + 2
    node_ids = ints.last(node_count)

    @elements[elem_id] = {
      nodes: node_ids,
      body: body,
      type: type,
      neighbors: []
    }
  end

  def spatial_dimension(epsilon = 1e-12)
    return 0 if @nodes.empty?

    axis_has_values = [false, false, false]
    @nodes.each_value do |coords|
      coords.each_with_index do |value, axis|
        axis_has_values[axis] ||= value.abs > epsilon
      end
    end

    [axis_has_values.count(true), 1].max
  end

  def bounds
    return nil if @nodes.empty?

    mins = @nodes.values.first.dup
    maxs = @nodes.values.first.dup

    @nodes.each_value do |coords|
      coords.each_with_index do |value, axis|
        mins[axis] = [mins[axis], value].min
        maxs[axis] = [maxs[axis], value].max
      end
    end

    {
      min: mins,
      max: maxs,
      size: mins.each_index.map { |axis| maxs[axis] - mins[axis] },
      center: mins.each_index.map { |axis| (mins[axis] + maxs[axis]) / 2.0 }
    }
  end

  def element_types
    @elements.values.map { |element| element[:type] }.uniq
  end

  # Save elements and nodes to JSON file
  def save_to_json(path)
    out = {
      nodes: @nodes,
      elements: @elements.transform_values do |v|
        {
          nodes: v[:nodes],
          centroid: v[:centroid],
          neighbors: v[:neighbors],
          body: v[:body],
          type: v[:type]
        }
      end,
      normals: @normals
    }
    File.write(path, JSON.pretty_generate(out))
  end

  # Возвращает новую Mesh, в которой каждому элементу назначено поле :body
  # Блок вызывается как: block.call(element_hash, original_mesh) и должен вернуть номер тела (Integer) или nil
  def with_updated_bodies
    raise ArgumentError, 'block required' unless block_given?

    # Неглубокое копирование узлов и глубокое копирование элементов
    new_mesh = Mesh.new
    new_mesh.instance_variable_set(:@nodes, @nodes.dup)
    new_mesh.instance_variable_set(:@normals, @normals.transform_values(&:dup))

    new_elements = {}
    @elements.each do |eid, data|
      new_elements[eid] = {
        nodes: data[:nodes].dup,
        centroid: data[:centroid] && data[:centroid].dup,
        neighbors: data[:neighbors].dup,
        body: data[:body],
        type: data[:type]
      }
    end
    new_mesh.instance_variable_set(:@elements, new_elements)

    new_elements.each do |_eid, data|
      # Передаем в блок элемент (hash) и оригинальную сетку (self) по ссылке
      val = yield(data, self)
      data[:body] = val unless val.nil?
    end

    new_mesh
  end

  # Сохраняет сетку в NAS (.nas) формате (пишет GRID и CTETRA строки).
  # Для CTETRA будет записан PID (body) если он присутствует у элемента.
  def save_to_nas(path)
    File.open(path, 'w') do |f|
      # Header / preamble similar to COMSOL export but branded for this tool
      f.puts '$ Generated by Black Suite'
      f.puts "$ #{Time.now.strftime('%b %d %Y, %H:%M')}"
      f.puts 'BEGIN BULK'
      f.puts '$ Grid data section'
      # Записать узлы в порядке возрастания id
      @nodes.keys.sort.each do |nid|
        coords = @nodes[nid]
        # Форматируем столбцами: идентификатор и 3 координаты с 5 знаками после запятой
        # Пример желаемого формата:
        # GRID           1         0.00000 0.00000 0.00000
        f.puts sprintf('GRID %8d %8.5f %8.5f %8.5f', nid, coords[0], coords[1], coords[2])
      end

      # Записать элементы в порядке возрастания id
      @elements.keys.sort.each do |eid|
        e = @elements[eid]
        nodes = e[:nodes]
        pid = e[:body] || 0
        case e[:type]
        when :triangle
          f.puts sprintf('%-8s%8d%8d%8d%8d%8d', 'CTRIA3', eid, pid, nodes[0], nodes[1], nodes[2])
        else
          f.puts sprintf('%-8s%8d%8d%8d%8d%8d%8d', 'CTETRA', eid, pid, nodes[0], nodes[1], nodes[2], nodes[3])
        end
      end

      bodies = @elements.values.map { |v| v[:body] }.compact.uniq.sort

      if bodies.any?
        f.puts '$ Property data section'
        bodies.each do |b|
          # Пишем PSOLID с выравниванием для читаемости
          f.puts sprintf('PSOLID %8d', b)
        end
        f.puts 'ENDDATA'
      end
    end
  end
end

if __FILE__ == $0
  # Default non-nil paths
  nas_path = File.join(__dir__, '..', 'work_dir', 'meshes', 'rod4.nas').to_s
  out_path = File.join(__dir__, '..', 'work_dir', 'mesh_elements.json').to_s

  # Override defaults only when ARGV entries are present and non-empty
  nas_path = ARGV[0] unless ARGV[0].nil? || ARGV[0].to_s.empty?
  out_path = ARGV[1] unless ARGV[1].nil? || ARGV[1].to_s.empty?

  puts "Loading mesh from: #{nas_path}..."
  mesh = Mesh.load_from_nas(nas_path)
  puts "Loaded nodes: #{mesh.nodes.size}, elements: #{mesh.elements.size}"

  # Quick statistics: average neighbors
  neigh_counts = mesh.elements.values.map { |e| e[:neighbors].size }
  avg_neigh = neigh_counts.reduce(0, :+).to_f / (neigh_counts.size.nonzero? || 1)
  puts "Average neighbors per element: #{avg_neigh.round(3)}"

  if out_path.downcase.end_with?('.nas')
    puts "Saving NAS to #{out_path}..."
    mesh.save_to_nas(out_path)
  else
    puts "Saving JSON to #{out_path}..."
    mesh.save_to_json(out_path)
  end
  puts "Done"
end
