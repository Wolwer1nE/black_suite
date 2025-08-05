require 'json'

class OptimizationConfig
  attr_reader :strategy, :parameters, :comsol, :output

  def initialize(config_file)
    @config_data = JSON.parse(File.read(config_file))

    @strategy = @config_data['strategy']
    @parameters = @config_data['parameters']
    @comsol = @config_data['comsol']
    @output = @config_data['output']

    validate_config
  end

  def method
    @strategy['method']
  end

  def max_generations
    @strategy['max_generations']
  end


  def create_genetic_strategy

    require_relative 'genetics/genetic_strategy'
    GeneticStrategy.new(
      population_size: @strategy['population_size'],
      iterations: @strategy['max_generations'],
      crossover_prob: @strategy['crossover_prob'],
      mutation_prob: @strategy['mutation_prob'],
      tournament_size: @strategy['tournament_size'],
      elite_count: @strategy['elite_count'],
      epsilon: @strategy['epsilon'],
      max_stagnant_epochs: @strategy['max_stagnant_epochs']
    )
  end

  def parameter_names
    @parameters['names']
  end

  def parameter_mins
    @parameters['mins']
  end

  def parameter_maxs
    @parameters['maxs']
  end

  def dimension
    @parameters['names'].length
  end

  def comsol_file
    @comsol['file']
  end

  def method_call
    @comsol['method_call']
  end

  def work_dir
    @comsol['work_dir'] || '.'
  end

  def silent_output?
    @comsol['silent_output']
  end

  def cache_file
    @output['cache_file']
  end

  def print_progress?
    @output['print_progress']
  end

  private

  def validate_config
    required_sections = %w[strategy parameters comsol output]
    required_sections.each do |section|
      raise "Отсутствует секция '#{section}' в конфигурации" unless @config_data[section]
    end

    strategy = @config_data['strategy']
    required_optimization = %w[max_generations population_size]
    required_optimization.each do |key|
      raise "Отсутствует параметр 'strategy.#{key}'" unless strategy[key]
    end

    required_parameters = %w[names mins maxs]
    required_parameters.each do |key|
      raise "Отсутствует параметр 'parameters.#{key}'" unless @parameters[key]
    end

    # Проверяем что размеры массивов совпадают
    names_count = @parameters['names'].length
    if @parameters['mins'].length != names_count || @parameters['maxs'].length != names_count
      raise "Количество имен, минимумов и максимумов параметров должно совпадать"
    end

    required_comsol = %w[file method_call]
    required_comsol.each do |key|
      raise "Отсутствует параметр 'comsol.#{key}'" unless @comsol[key]
    end

    required_output = %w[cache_file]
    required_output.each do |key|
      raise "Отсутствует параметр 'output.#{key}'" unless @output[key]
    end
  end
end
