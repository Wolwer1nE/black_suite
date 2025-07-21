require 'sinatra'
require 'json'
require 'fileutils'
require_relative 'src/project'
include Project
get '/' do
  erb :index
end

# Страница создания задачи
get '/task/new' do
  erb :task_form, locals: { mode: 'new', task: nil }
end

get '/task/edit/:task_name' do
  task_dir = File.join('data', params[:task_name])
  task_file = File.join(task_dir, 'task.json')
  if File.exist?(task_file)
    task = JSON.parse(File.read(task_file))
    erb :task_form, locals: { mode: 'edit', task: task }
  else
    halt 404, "Задача не найдена"
  end
end


get '/task/:task_name' do
  task_dir = File.join('data', params[:task_name])
  task_file = File.join(task_dir, 'task.json')
  if File.exist?(task_file)
    content_type :json
    File.read(task_file)
  else
    halt 404, { error: 'Задача не найдена' }.to_json
  end
end

get '/tree' do


  content_type :json
  tree('data').to_json
end


get '/surface' do
  filename = params['file']
  halt 400, { error: 'No file specified' }.to_json unless filename

  path = File.join('data', filename)
  halt 404, { error: 'File not found' }.to_json unless File.exist?(path)

  x, y, z = [], [], []
  File.foreach(path) do |line|
    cols = line.strip.split("\t")
    next unless cols.size >= 3
    x << cols[0].to_f
    y << cols[1].to_f
    z << cols[2].to_f
  end

  x_uniq = x.uniq.sort
  y_uniq = y.uniq.sort
  z_matrix = Array.new(y_uniq.size) { Array.new(x_uniq.size) }

  x.size.times do |i|
    xi = x_uniq.index(x[i])
    yi = y_uniq.index(y[i])
    z_matrix[yi][xi] = z[i]
  end

  content_type :json
  { x: x_uniq, y: y_uniq, z: z_matrix }.to_json
end

post '/create_task' do
  task_name = params[:task_name]

  halt 400, { error: 'Missing fields' }.to_json unless task_name && params
  project_dir = File.join('data', task_name)
  Dir.mkdir(project_dir) unless Dir.exist?(project_dir)

  settings = {
    'task_name' => task_name,
    'params' => []
  }
  File.write(File.join(project_dir, 'settings.json'), JSON.pretty_generate(settings))

  redirect '/'
end

post '/save_settings' do
  req = JSON.parse(request.body.read)
  task_name = req['task_name']
  params = req['params']
  halt 400, { error: 'Missing fields' }.to_json unless task_name && params

  project_dir = File.join('data', task_name)
  settings_path = File.join(project_dir, 'settings.json')
  if !Dir.exist?(project_dir)
    halt 404, { error: 'Задача не найдена' }.to_json
  end

  settings = {
    'task_name' => task_name,
    'params' => params
  }
  File.write(settings_path, JSON.pretty_generate(settings))
  status 200
  body 'ok'
end


