require 'sinatra'
require 'json'
require 'fileutils'
require_relative 'src/optimization_cache_dto'
require_relative 'src/shape_repository'
require_relative 'src/shape_optimization_job_manager'

ROOT_DIR = File.expand_path('..', __dir__)
SHAPE_OPTIMIZATION_JOB_MANAGER = ShapeOptimizationJobManager.new(ROOT_DIR)

def cache_manager
  OptimizationCacheManager.new(File.join(ROOT_DIR, 'work_dir'))
end

def shape_repository
  ShapeRepository.new(File.join(ROOT_DIR, 'data', 'shapes'))
end

get '/' do
  erb :index
end

get '/shapes' do
  erb :shapes
end

# Получить список всех кэшей с метаданными
get '/caches' do
  content_type :json

  caches = cache_manager.scan_and_load_caches

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

  caches = cache_manager.scan_and_load_caches

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
    points: points,
    best_fitness_history: cache.best_fitness_history || [] # <--- добавлено
  }
  result.to_json
end

get '/api/shapes' do
  content_type :json
  shape_repository.scan_shapes.to_json
end

get '/api/shapes/:shape_id' do
  content_type :json

  shape = shape_repository.load_shape(params[:shape_id], displacement_file: params[:displacement_file])
  halt 404, { error: 'Фигура не найдена' }.to_json unless shape

  shape.to_json
end

post '/api/shapes/:shape_id/displacements' do
  content_type :json

  raw_body = request.body.read
  request_data = raw_body.empty? ? {} : JSON.parse(raw_body)

  shape = shape_repository.generate_displacements(
    params[:shape_id],
    iterations: (request_data['iterations'] || 3).to_i,
    lambda: (request_data['lambda'] || 0.25).to_f,
    mu: request_data.key?('mu') && !request_data['mu'].to_s.strip.empty? ? request_data['mu'].to_f : nil,
    max_step: request_data.key?('max_step') && !request_data['max_step'].to_s.strip.empty? ? request_data['max_step'].to_f : nil,
    mode: request_data['smoothing_mode'] || 'legacy'
  )

  halt 404, { error: 'Фигура не найдена' }.to_json unless shape

  status 201
  shape.to_json
rescue JSON::ParserError => e
  halt 400, { error: "Некорректный JSON: #{e.message}" }.to_json
rescue StandardError => e
  halt 422, { error: e.message }.to_json
end

post '/api/shapes/:shape_id/optimization' do
  content_type :json

  entry = shape_repository.shape_entry(params[:shape_id])
  halt 404, { error: 'Фигура не найдена' }.to_json unless entry

  support = shape_repository.optimization_support(params[:shape_id])
  if support && !support[:supported]
    halt 422, { error: support[:reason] }.to_json
  end

  raw_body = request.body.read
  request_data = raw_body.empty? ? {} : JSON.parse(raw_body)

  job = SHAPE_OPTIMIZATION_JOB_MANAGER.start_or_reuse_job(
    shape_id: params[:shape_id],
    mesh_path: entry[:mesh_path],
    options: {
      session_name: request_data['session_name'],
      sigma: request_data['sigma'] || 0.3,
      max_evaluations: request_data['max_evaluations'] || 1000,
      max_generations: request_data['max_generations'] || 500,
      target_fitness: request_data.key?('target_fitness') && !request_data['target_fitness'].to_s.strip.empty? ? request_data['target_fitness'].to_f : nil,
      workers: request_data['workers'] || 8,
      parallel: request_data.key?('parallel') ? request_data['parallel'] : true,
      pre_smoothing_mode: request_data['pre_smoothing_mode'] || 'none',
      smooth_iterations: request_data['smooth_iterations'] || 1,
      smooth_lambda: request_data['smooth_lambda'] || 0.25,
      smooth_mu: request_data.key?('smooth_mu') && !request_data['smooth_mu'].to_s.strip.empty? ? request_data['smooth_mu'].to_f : nil,
      smooth_max_step: request_data.key?('smooth_max_step') && !request_data['smooth_max_step'].to_s.strip.empty? ? request_data['smooth_max_step'].to_f : nil
    }
  )

  status(job[:reused] ? 200 : 202)
  job.to_json
rescue JSON::ParserError => e
  halt 400, { error: "Некорректный JSON: #{e.message}" }.to_json
rescue StandardError => e
  halt 422, { error: e.message }.to_json
end

get '/api/shapes/:shape_id/optimization/active' do
  content_type :json

  support = shape_repository.optimization_support(params[:shape_id])
  if support && !support[:supported]
    halt 404, { error: support[:reason] }.to_json
  end

  job = SHAPE_OPTIMIZATION_JOB_MANAGER.active_job_for_shape(params[:shape_id])
  halt 404, { error: 'Активная оптимизация не найдена' }.to_json unless job

  job.to_json
end

get '/api/shape-optimization/jobs/:job_id' do
  content_type :json

  job = SHAPE_OPTIMIZATION_JOB_MANAGER.job_status(params[:job_id])
  halt 404, { error: 'Задача не найдена' }.to_json unless job

  job.to_json
end
