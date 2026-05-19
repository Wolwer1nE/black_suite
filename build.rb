#!/usr/bin/env ruby

require 'fileutils'
require 'rbconfig'

target = ARGV[0] || '.'

unless Dir.exist?(target) || File.file?(target)
  warn "Error: '#{target}' does not exist"
  warn 'Usage: ruby build.rb <folder_or_tex_file>'
  exit 1
end

def tex_files_from(target)
  if File.file?(target)
    return [] unless File.extname(target).downcase == '.tex'

    [File.expand_path(target)]
  else
    pattern = File.join(target, '**', '*.tex')
    Dir.glob(pattern)
       .reject { |f| f.include?("#{File::SEPARATOR}build#{File::SEPARATOR}") }
       .map { |f| File.expand_path(f) }
  end
end

def run_pdflatex(working_dir:, tex_basename:, output_dir:)
  FileUtils.mkdir_p(output_dir)

  args = [
    'pdflatex',
    '-synctex=1',
    '-interaction=nonstopmode',
    '-file-line-error',
    "-output-directory=#{output_dir}",
    tex_basename
  ]

  2.times.all? do
    Dir.chdir(working_dir) { system(*args) }
  end
end

def cleanup_build(output_dir)
  Dir.glob(File.join(output_dir, '*')).each do |path|
    next if File.directory?(path)
    next if File.extname(path).downcase == '.pdf'

    File.delete(path)
  end
end

tex_files = tex_files_from(target)

if tex_files.empty?
  warn "No .tex files found for '#{target}'"
  exit 1
end

puts "Ruby:    #{RbConfig.ruby}"
puts "Target:  #{File.expand_path(target)}"
puts "Found:   #{tex_files.size} tex file(s)"

failed = []

tex_files.each do |tex_file|
  working_dir = File.dirname(tex_file)
  tex_basename = File.basename(tex_file)
  output_dir = File.join(working_dir, 'build')

  puts "\n==> Building #{tex_file}"

  ok = run_pdflatex(
    working_dir: working_dir,
    tex_basename: tex_basename,
    output_dir: output_dir
  )

  if ok
    cleanup_build(output_dir)
    puts "OK: #{File.join(output_dir, File.basename(tex_basename, '.tex') + '.pdf')}"
  else
    failed << tex_file
    warn "FAILED: #{tex_file}"
  end
end

if failed.empty?
  puts "\nDone: all files compiled successfully."
  exit 0
else
  warn "\nDone with errors (#{failed.size}):"
  failed.each { |f| warn "  - #{f}" }
  exit 1
end