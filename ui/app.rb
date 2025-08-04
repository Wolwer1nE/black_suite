require 'sinatra'
require 'json'
require 'fileutils'
require_relative 'src/optimization_cache_dto'

get '/' do
  erb :index
end

# Получить список всех кэшей с метаданными
get '/caches' do
  content_type :json

  work_cache_manager = OptimizationCacheManager.new('../work_dir')
  caches = work_cache_manager.scan_and_load_caches

  result = caches.map do |cache_info|
    cache = cache_info[:cache]
    fitnesses = cache.entries.map(&:fitness)
    {
      id: File.basename(cache_info[:file_path], '.json'),
      file_path: cache_info[:file_path],
      file_name: File.basename(cache_info[:file_path]),
      timestamp: cache.timestamp,
      total_evaluations: cache.total_evaluations,
      dimension: cache.dimension,
      names: cache.names,
      comsol_file: cache.comsol_file,
      best_point: cache.entries.min_by(&:fitness).values,
      best_fitness: fitnesses.min,
      worst_fitness: fitnesses.max
    }
  end

  result.to_json
end

# Получить детальную информацию о конкретном кэше
get '/cache/:cache_id' do
  content_type :json
  cache_id = params[:cache_id]

  work_cache_manager = OptimizationCacheManager.new('../work_dir')
  caches = work_cache_manager.scan_and_load_caches

  cache_info = caches.find do |info|
    File.basename(info[:file_path], '.json') == cache_id
  end

  halt 404, { error: 'Кэш не найден' }.to_json unless cache_info

  cache = cache_info[:cache]

  # Подготавливаем данные для графиков
  points = cache.entries.map do |entry|
    {
      values: entry.values,
      fitness: entry.fitness
    }
  end

  # Статистика
  fitnesses = cache.entries.map(&:fitness)

  result = {
    id: cache_id,
    file_name: File.basename(cache_info[:file_path]),
    timestamp: cache.timestamp,
    total_evaluations: cache.total_evaluations,
    dimension: cache.dimension,
    parameter_names: cache.names,
    mins: cache.mins,
    maxs: cache.maxs,
    comsol_file: cache.comsol_file,
    methodcall: cache.methodcall,
    statistics: {
      best_fitness: fitnesses.min,
      worst_fitness: fitnesses.max,
      average_fitness: fitnesses.sum / fitnesses.size.to_f,
      median_fitness: fitnesses.sort[fitnesses.size / 2],
      best_point: cache.entries.min_by(&:fitness).values
    },
    points: points
  }

  result.to_json
end
