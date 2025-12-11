# Добавляет реализацию Latin Hypercube Sampling (LHS).
# Модуль предоставляет метод LHS.sample(n, dims, lower_bounds=0.0, upper_bounds=1.0, rng: Random.new)
# Примеры:
#   LHS.sample(5, 3) # 5 точек в 3D в диапазоне [0,1]
#   LHS.sample(10, 2, [0, -5], [1, 5])
#   LHS.sample(4, 1, 10, 20) # 4 точек в 1D в диапазоне [10,20]

module LHS
  # Выполняет Latin Hypercube Sampling.
  # n - количество точек (Integer > 0)
  # dims - число измерений (Integer > 0)
  # lower_bounds, upper_bounds - либо числа (скаляр), либо массивы длины dims
  # rng: можно передать объект Random (например Random.new(seed)) для детерминизма
  # Возвращает массив из n массивов длины dims.
  def self.sample(n, dims = nil, lower_bounds = 0.0, upper_bounds = 1.0, rng: nil)
    raise ArgumentError, "n must be positive Integer" unless n.is_a?(Integer) && n > 0

    rng = rng || Random.new

    # Если dims не указан, попытаться вывести из размеров нижних/верхних границ
    if dims.nil?
      if lower_bounds.is_a?(Array)
        dims = lower_bounds.length
      elsif upper_bounds.is_a?(Array)
        dims = upper_bounds.length
      else
        raise ArgumentError, "dims must be provided when bounds are scalars"
      end
    end

    raise ArgumentError, "dims must be positive Integer" unless dims.is_a?(Integer) && dims > 0

    # Нормализуем bounds к массивам длины dims
    lower = if lower_bounds.is_a?(Array)
              raise ArgumentError, "lower_bounds length mismatch with dims" unless lower_bounds.length == dims
              lower_bounds.map(&:to_f)
            else
              Array.new(dims, lower_bounds.to_f)
            end

    upper = if upper_bounds.is_a?(Array)
              raise ArgumentError, "upper_bounds length mismatch with dims" unless upper_bounds.length == dims
              upper_bounds.map(&:to_f)
            else
              Array.new(dims, upper_bounds.to_f)
            end

    (0...dims).each do |i|
      raise ArgumentError, "upper_bounds[#{i}] must be > lower_bounds[#{i}]" unless upper[i] > lower[i]
    end

    # Для каждого измерения создаём n интервалов и равномерно внутри них случайные точки, затем перемешиваем
    # Создаём матрицу n x dims
    samples = Array.new(n) { Array.new(dims, 0.0) }

    dims.times do |d|
      # base points: (i + u)/n, u ~ U(0,1)
      strata = Array.new(n) { |i| (i + rng.rand) / n.to_f }
      # shuffle strata
      strata = strata.shuffle(random: rng)

      range = upper[d] - lower[d]
      n.times do |i|
        samples[i][d] = lower[d] + strata[i] * range
      end
    end

    samples
  end
end

# CLI: запуск из командной строки
if __FILE__ == $0
  require 'optparse'
  require 'json'
  require 'csv'

  options = {
    n: nil,
    dims: nil,
    lower: nil,
    upper: nil,
    seed: nil,
    format: 'json',
    out: nil
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby lhs.rb [options]"

    opts.on('-nN', '--n=N', Integer, 'Number of samples (required)') { |v| options[:n] = v }
    opts.on('-dD', '--dims=D', Integer, 'Number of dimensions (optional if bounds arrays provided)') { |v| options[:dims] = v }
    opts.on('--lower=VALS', 'Lower bounds: scalar or comma-separated list (e.g. 0 or 0,0,100)') { |v| options[:lower] = v }
    opts.on('--upper=VALS', 'Upper bounds: scalar or comma-separated list (e.g. 1 or 1,10,200)') { |v| options[:upper] = v }
    opts.on('--seed=SEED', Integer, 'RNG seed (optional)') { |v| options[:seed] = v }
    opts.on('-fFMT', '--format=FMT', %w[json csv], 'Output format: json or csv (default: json)') { |v| options[:format] = v }
    opts.on('-oFILE', '--out=FILE', 'Write output to FILE instead of stdout') { |v| options[:out] = v }

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

  parse_bounds = lambda do |str|
    next nil if str.nil?
    # comma-separated list -> array of floats, otherwise scalar float
    if str.include?(',')
      str.split(',').map { |s| Float(s) }
    else
      Float(str)
    end
  end

  lower = parse_bounds.call(options[:lower]) || 0.0
  upper = parse_bounds.call(options[:upper]) || 1.0
  dims = options[:dims]
  rng = options[:seed] ? Random.new(options[:seed]) : nil

  begin
    samples = LHS.sample(options[:n], dims, lower, upper, rng: rng)
  rescue ArgumentError => e
    STDERR.puts "Error: #{e.message}"
    exit 2
  end

  # Prepare output
  out_io = options[:out] ? File.open(options[:out], 'w') : $stdout
  begin
    case options[:format]
    when 'json'
      out_io.puts JSON.generate(samples)
    when 'csv'
      # write each sample as a CSV row
      csv = CSV.new(out_io)
      samples.each { |row| csv << row }
    else
      out_io.puts JSON.generate(samples)
    end
  ensure
    out_io.close if options[:out]
  end
end
