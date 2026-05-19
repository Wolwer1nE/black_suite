# frozen_string_literal: true

require 'json'

# Накопитель данных для surrogate-based оптимизации.
# Хранит уникальные точки, умеет подтягивать исторические кэши и проверять совместимость.
class SurrogateDataset
  Entry = Struct.new(:values, :fitness, :source, keyword_init: true)

  attr_reader :names, :mins, :maxs, :entries

  def initialize(names:, mins:, maxs:, duplicate_precision: 8)
    @names = names.dup
    @mins = mins.map(&:to_f)
    @maxs = maxs.map(&:to_f)
    @duplicate_precision = duplicate_precision
    @entries = []
    @index = {}
  end

  def dimension
    @names.length
  end

  def size
    @entries.size
  end

  def samples
    @entries.map(&:values)
  end

  def fitnesses
    @entries.map(&:fitness)
  end

  def best_entry
    @entries.min_by(&:fitness)
  end

  def best_sample
    best_entry&.values
  end

  def best_fitness
    best_entry&.fitness || Float::INFINITY
  end

  def empty?
    @entries.empty?
  end

  def add_sample(values, fitness, source: 'solver')
    normalized = normalize_values(values)
    key = key_for(normalized)
    existing = @index[key]

    if existing
      if fitness.to_f < existing.fitness.to_f
        existing.fitness = fitness.to_f
        existing.source = source
      end
      return existing
    end

    entry = Entry.new(values: normalized, fitness: fitness.to_f, source: source)
    @entries << entry
    @index[key] = entry
    entry
  end

  def add_batch(points, fitnesses, source: 'solver')
    points.each_with_index.map do |point, idx|
      add_sample(point, fitnesses[idx], source: source)
    end
  end

  def import_cache_glob(pattern)
    Dir.glob(pattern).sort.each do |file_path|
      import_cache_file(file_path)
    end
  end

  def import_cache_file(file_path)
    return 0 unless File.exist?(file_path)

    data = JSON.parse(File.read(file_path))
    return 0 unless compatible_cache?(data)

    imported = 0
    cache_entries = data['cache'] || {}
    cache_entries.each_value do |entry|
      values = entry['values'] || entry[:values]
      fitness = entry['fitness'] || entry[:fitness]
      next unless values && fitness

      add_sample(values, fitness, source: File.basename(file_path))
      imported += 1
    end

    imported
  rescue JSON::ParserError
    0
  end

  def compatible_cache?(data)
    return false unless data['dimension'].to_i == dimension
    return false unless array_equal?(data['names'], @names)
    return false unless float_arrays_close?(data['mins'], @mins)
    return false unless float_arrays_close?(data['maxs'], @maxs)

    true
  end

  def include_close_sample?(candidate, threshold: default_distance_threshold)
    return false if empty?

    candidate = normalize_values(candidate)
    @entries.any? do |entry|
      normalized_distance(entry.values, candidate) <= threshold
    end
  end

  def normalized_distance(left, right)
    squared = left.each_with_index.sum do |value, idx|
      range = [@maxs[idx] - @mins[idx], 1e-12].max
      ((value - right[idx]) / range) ** 2
    end
    Math.sqrt(squared)
  end

  def default_distance_threshold
    0.02 * Math.sqrt(dimension)
  end

  def cache_hash
    result = {}
    @entries.each do |entry|
      result[key_for(entry.values)] = {
        fitness: entry.fitness,
        values: entry.values.dup,
        source: entry.source
      }
    end
    result
  end

  private

  def normalize_values(values)
    values.each_with_index.map do |value, idx|
      value.to_f.clamp(@mins[idx], @maxs[idx])
    end
  end

  def key_for(values)
    values.map { |value| value.round(@duplicate_precision) }.join('_')
  end

  def array_equal?(left, right)
    return false unless left.is_a?(Array) && right.is_a?(Array)
    return false unless left.length == right.length

    left.zip(right).all? { |a, b| a.to_s == b.to_s }
  end

  def float_arrays_close?(left, right, epsilon: 1e-9)
    return false unless left.is_a?(Array) && right.is_a?(Array)
    return false unless left.length == right.length

    left.zip(right).all? { |a, b| (a.to_f - b.to_f).abs <= epsilon }
  end
end
