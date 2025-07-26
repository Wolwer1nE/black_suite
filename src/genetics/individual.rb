class Individual
  attr_accessor :id, :values, :genome, :mins, :maxs, :names, :fitness
  BITS = 32
  def initialize(id, values, mins: nil, maxs: nil, names: nil)
    @id = id
    @values = values
    @mins = mins || Array.new(values.size, -1.0)
    @maxs = maxs || Array.new(values.size, 1.0)
    @names = names || Array.new(values.size) { |i| "x#{i + 1}" }
    @fitness = 10e12
    encode
  end


  def encode(bits: BITS)
    @genome = @values.each_with_index.flat_map do |v, i|
      min = @mins[i]
      max = @maxs[i]
      int = (((v - min) / (max - min)) * ((1 << bits) - 1)).round
      int.to_s(2).rjust(bits, '0').chars.map(&:to_i)
    end
  end

  def decode(bits: BITS)
    @genome.each_slice(bits).each_with_index.map do |slice, i|
      int = slice.join.to_i(2)
      min = @mins[i]
      max = @maxs[i]
      min + (int.to_f / ((1 << bits) - 1)) * (max - min)
    end
  end

  def compute_fitness(&block)
    @fitness = block.call(@values)
  end


  def mutate(mutation_rate: 0.01)
    new_individual = dup

    new_individual.genome.map! do |bit|
      rand < mutation_rate ? 1 - bit : bit
    end
    new_individual.values = new_individual.decode
    new_individual
  end

  def values_view
    @values.join(',')
  end

  def crossover(other)
    new_individual = dup
    new_individual.genome = genome.zip(other.genome) do |left, right|
      rand > 0.5 ? left : right
    end
    new_individual.values = new_individual.decode
    new_individual
  end
end
