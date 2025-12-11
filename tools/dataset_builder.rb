# tools/dataset_builder.rb
# Утилита для генерации наборов параметров с помощью Latin Hypercube Sampling (LHS)
# Формирует файл параметров в том же формате, что и create_parameter_file в ComsolGeneticOptimizer

require 'json'
require 'optparse'
require_relative 'lhs'

module DatasetBuilder
  module_function

  # contract:
  # - input: params_hash with keys: "names" (array), "mins" (array), "maxs" (array)
  # - n: number of samples
  # - seed: optional RNG seed
  # - out_path: path to write the parameter file
  # - returns: { param_file: relative_path_string, command: comsol_command_string, samples: samples }
  def build_from_config(params_hash, n:, out_path: 'batch_params.txt', seed: nil, work_dir: '.')
    names = params_hash['names'] || params_hash[:names]
    mins = params_hash['mins'] || params_hash[:mins]
    maxs = params_hash['maxs'] || params_hash[:maxs]

    raise ArgumentError, 'names, mins and maxs must be provided and arrays of same length' unless [names, mins, maxs].all? { |x| x.is_a?(Array) }
    raise ArgumentError, 'names, mins and maxs must have same length' unless names.length == mins.length && names.length == maxs.length

    dims = names.length
    rng = seed ? Random.new(seed) : Random.new

    samples = LHS.sample(n, dims, mins, maxs, rng: rng)

    # write file in the same format as create_parameter_file
    full_out_path = File.expand_path(out_path, work_dir)
    dirname = File.dirname(full_out_path)
    Dir.mkdir(dirname) unless Dir.exist?(dirname)

    File.open(full_out_path, 'w') do |f|
      f.puts names.join(' ')
      samples.each do |sample|
        f.puts sample.map { |v| format('%.8f', v) }.join(' ')
      end
    end

    # Формируем строку для запуска COMSOL. В проекте используется ComsolRunner, который, судя по коду,
    # запускает COMSOL отдельно и ожидает файлы в work_dir. Здесь сформируем рекомендованную команду.
    # Пользователь может изменить путь к comsol.exe и опции по необходимости.
    comsol_file_placeholder = File.basename(Dir['*.mph'].first || 'model.mph')
    comsol_cmd = "comsol batch -inputfile #{comsol_file_placeholder} -outputfile #{File.basename(out_path)}"

    { param_file: File.basename(out_path), full_path: full_out_path, command: comsol_cmd, samples: samples }
  end
end

# CLI
if __FILE__ == $0
  options = {
    config: nil,
    n: nil,
    out: 'batch_params.txt',
    seed: nil,
    work_dir: '.'
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby dataset_builder.rb [options]"

    opts.on('--config=FILE', 'JSON file with parameters: { "names": [...], "mins": [...], "maxs": [...] }') { |v| options[:config] = v }
    opts.on('-nN', '--n=N', Integer, 'Number of samples to generate (required)') { |v| options[:n] = v }
    opts.on('-oFILE', '--out=FILE', 'Output parameter file (default: batch_params.txt)') { |v| options[:out] = v }
    opts.on('--seed=SEED', Integer, 'RNG seed (optional)') { |v| options[:seed] = v }
    opts.on('--work-dir=DIR', 'Work directory for output (default: current)') { |v| options[:work_dir] = v }
    opts.on_tail('-h', '--help', 'Show this message') do
      puts opts
      exit
    end
  end

  begin
    parser.parse!(ARGV)
  rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
    STDERR.puts "Error: #{e.message}"
    STDERR.puts parser
    exit 2
  end

  if options[:n].nil?
    STDERR.puts "Error: -n/--n is required"
    STDERR.puts parser
    exit 2
  end

  if options[:config]
    begin
      params = JSON.parse(File.read(options[:config]))
    rescue => e
      STDERR.puts "Failed to read config file: #{e.message}"
      exit 2
    end
  else
    STDERR.puts "Error: --config is required"
    exit 2
  end

  begin
    result = DatasetBuilder.build_from_config(params, n: options[:n], out_path: options[:out], seed: options[:seed], work_dir: options[:work_dir])
  rescue => e
    STDERR.puts "Error: #{e.message}"
    exit 2
  end

  puts "Parameter file written: #{result[:full_path]}"
  puts "COMSOL command (suggested): #{result[:command]}"
end
