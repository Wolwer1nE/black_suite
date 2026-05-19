# frozen_string_literal: true

require_relative '../genetics/comsol_genetic_optimizer'
require_relative 'hybrid_ai_optimizer'

# Единая точка создания оптимизаторов для параметрических задач.
class OptimizerFactory
  def self.build(config)
    case config.optimizer_method
    when 'hybrid_ai', 'hybrid', 'ai'
      HybridAIOptimizer.new(config)
    when 'genetic', 'ga', nil
      ComsolGeneticOptimizer.new(config)
    else
      raise ArgumentError, "Неизвестный метод оптимизации: #{config.optimizer_method.inspect}"
    end
  end
end
