#!/usr/bin/env ruby

require 'rbconfig'

if ARGV.length < 1
  puts "Usage: ruby watch.rb <folder>"
  exit 1
end

folder = File.expand_path(ARGV[0])
script_dir = File.expand_path(__dir__)
build_script = File.join(script_dir, 'build.rb')

unless Dir.exist?(folder)
  puts "Error: Folder '#{folder}' does not exist"
  exit 1
end

# Get initial file mtimes
file_mtimes = {}

def get_tex_files(folder)
  Dir.glob(File.join(folder, "**/*.tex"))
end

def update_mtimes(folder, mtimes)
  get_tex_files(folder).each do |file|
    mtimes[file] = File.mtime(file)
  end
end

# Initialize mtimes
update_mtimes(folder, file_mtimes)

puts "Watching TeX files in '#{folder}'..."
puts "Press Ctrl+C to stop."

loop do
  sleep 1
  
  changed = false
  
  # Check for modified files
  get_tex_files(folder).each do |file|
    current_mtime = File.mtime(file)
    
    if file_mtimes[file].nil? || current_mtime > file_mtimes[file]
      changed = true
      file_mtimes[file] = current_mtime
    end
  end
  
  # Check for deleted files
  file_mtimes.each_key do |file|
    unless File.exist?(file)
      changed = true
      file_mtimes.delete(file)
    end
  end
  
  if changed
    puts "\n[#{Time.now}] Changes detected! Running build..."
    system(RbConfig.ruby, build_script, folder)
  end
end
