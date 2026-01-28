require_relative '../src/optimization/cma_es'
require_relative '../src/simple_logger'

optimizer = CmaEs.new(
  dimension: 100,
  mins: Array.new(100) { |i| -0.001 * (i+1) },  
  maxs: Array.new(100) { |i|  0.001 * (i+1) },
  sigma: 0.3,
  max_evaluations: 10_000,
  logger: SimpleLogger.new
)

result = optimizer.run { |x| your_solver(x) }
# x — массив Float, возвращает Float (fitness)

def acelan_solver

end