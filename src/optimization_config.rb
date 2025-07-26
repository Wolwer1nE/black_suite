require 'json'

class OptimizationConfig
  attr_reader :optimization, :parameters, :comsol, :output

  def initialize(config_file)
    @config_data = JSON.parse(File.read(config_file))

    @optimization = @config_data['optimization']
    @parameters = @config_data['parameters']
    @comsol = @config_data['comsol']
    @output = @config_data['output']

    validate_config
  end

  def method
    @optimization['method']
  end

  def max_generations
    @optimization['max_generations']
  end

  def batch_size
    @optimization['batch_size']
  end

  def create_genetic_strategy
    strategy_config = @optimization['strategy']

    require_relative 'genetics/genetic_strategy'
    GeneticStrategy.new(
      population_size: strategy_config['population_size'],
      iterations: @optimization['max_generations'],
      crossover_prob: strategy_config['crossover_prob'],
      mutation_prob: strategy_config['mutation_prob'],
      tournament_size: strategy_config['tournament_size'],
      elite_count: strategy_config['elite_count'],
      epsilon: strategy_config['epsilon'],
      max_stagnant_epochs: strategy_config['max_stagnant_epochs']
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
    required_sections = %w[optimization parameters comsol output]
    required_sections.each do |section|
      raise "Отсутствует секция '#{section}' в конфигурации" unless @config_data[section]
    end

    required_optimization = %w[method max_generations batch_size strategy]
    required_optimization.each do |key|
      raise "Отсутствует параметр 'optimization.#{key}'" unless @optimization[key]
    end

    # Проверяем параметры strategy
    if @optimization['strategy']
      required_strategy = %w[population_size crossover_prob mutation_prob tournament_size elite_count]
      required_strategy.each do |key|
        raise "Отсутствует параметр 'optimization.strategy.#{key}'" unless @optimization['strategy'][key]
      end
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
