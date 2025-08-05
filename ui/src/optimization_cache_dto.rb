require 'json'

class CacheEntry
  attr_accessor :fitness, :values

  def initialize(fitness, values)
    @fitness = fitness
    @values = values
  end

  def to_h
    {
      fitness: @fitness,
      values: @values
    }
  end
end


class OptimizationCache
  attr_accessor :total_evaluations, :timestamp,
                :dimension, :names, :mins, :maxs,
                :comsol_file, :methodcall, :cache, :best_fitness_history

  def initialize
    @cache = {}
    @best_fitness_history = []
  end

  def self.from_json(json_data)
    cache = new

    cache.total_evaluations = json_data['total_evaluations']
    cache.timestamp = json_data['timestamp']
    cache.dimension = json_data['dimension']
    cache.names = json_data['names']
    cache.mins = json_data['mins']
    cache.maxs = json_data['maxs']

    cache.comsol_file = json_data['comsol_file']
    cache.methodcall = json_data['methodcall']
    cache.best_fitness_history = json_data['best_fitness_history'] || []

    if json_data['cache']
      json_data['cache'].each do |key, entry_data|
        cache.cache[key] = CacheEntry.new(entry_data['fitness'], entry_data['values'])
      end
    end
    cache
  end

  def to_h
    {
      total_evaluations: @total_evaluations,
      timestamp: @timestamp,
      dimension: @dimension,
      names: @names,
      mins: @mins,
      maxs: @maxs,
      best: @best,
      comsol_file: @comsol_file,
      methodcall: @methodcall,
      cache: @cache.transform_values(&:to_h)
    }
  end
  def statistics
    fitnesses = entries.map(&:fitness)
    {
      id: File.basename(cache_info[:file_path], '.json'),
      file_path: cache_info[:file_path],
      file_name: File.basename(cache_info[:file_path]),
      timestamp: cache.timestamp,
      total_evaluations: cache.total_evaluations,
      dimension: cache.dimension,
      names: cache.names,
      comsol_file: cache.comsol_file,
      best_point: cache.entries.min_by(&:fitness)&.values,
      best_fitness: fitnesses.min,
      worst_fitness: fitnesses.max
    }
  end

  def entries
    @cache.values
  end

  def add_entry(fitness, values)
    key = @cache.size.to_s
    @cache[key] = CacheEntry.new(fitness, values)
    @total_evaluations = (@total_evaluations || 0) + 1
  end

  def to_json(*_args)
    JSON.generate(to_h)
  end

end

class OptimizationCacheManager
  def initialize(data_dir = 'ui/data')
    @data_dir = data_dir
  end

  def scan_and_load_caches
    caches = []

    Dir.glob(File.join(@data_dir, '**', '*.json')).each do |json_file|
      begin
        json_content = File.read(json_file, encoding: 'utf-8')
        parsed_data = JSON.parse(json_content)

        if is_optimization_cache?(parsed_data)
          cache = OptimizationCache.from_json(parsed_data)
          caches << {
            file_path: json_file,
            cache: cache
          }
        end
      rescue JSON::ParserError => e
        # Игнорируем файлы с неправильным JSON
      rescue => e
        # Игнорируем другие ошибки
      end
    end

    caches
  end

  # Объединяет все кэши в один
  def merge_caches(caches)
    return nil if caches.empty?

    merged = OptimizationCache.new
    first_cache = caches.first[:cache]

    # Копируем метаданные из первого кэша
    merged.dimension = first_cache.dimension
    merged.names = first_cache.names
    merged.mins = first_cache.mins
    merged.maxs = first_cache.maxs
    merged.comsol_file = first_cache.comsol_file
    merged.methodcall = first_cache.methodcall
    merged.timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")

    total_evaluations = 0
    cache_index = 0

    caches.each do |cache_info|
      cache = cache_info[:cache]
      cache.entries.each do |entry|
        merged.cache[cache_index.to_s] = entry
        cache_index += 1
      end
      total_evaluations += cache.total_evaluations || 0
    end

    merged.total_evaluations = total_evaluations
    merged
  end



  private

  # Проверяет, является ли JSON файл optimization_cache
  def is_optimization_cache?(data)
    required_fields = %w[total_evaluations dimension names cache]
    required_fields.all? { |field| data.key?(field) }
  end
end
