require 'rack/mock'
begin
  require_relative 'ui/app'
rescue LoadError => e
  puts "LoadError: #{e.message}"
  puts e.backtrace.first(5)
  exit
rescue => e
  puts "#{e.class}: #{e.message}"
  puts e.backtrace.first(5)
  exit
end

app = Sinatra::Application

['/api/shapes', '/api/shapes/shear_bender'].each do |path|
  env = Rack::MockRequest.env_for(path)
  status, headers, body = app.call(env)
  
  puts "PATH: #{path}"
  puts "STATUS: #{status}"
  
  body_text = ""
  body.each { |part| body_text << part }
  puts "BODY (first 200 chars): #{body_text[0..200]}..."
  puts "-" * 20
end
