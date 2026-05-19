# frozen_string_literal: true

# Лёгкий surrogate backend без внешних зависимостей.
# Идея: локальная регрессия по ближайшим соседям с весами 1 / distance.
# Возвращает:
# - :mean — предсказанное значение цели
# - :uncertainty — прокси для неопределённости (локальная вариативность + sparsity)
class InverseDistanceBackend
  def initialize(k_neighbors: 8, epsilon: 1e-9)
    @k_neighbors = k_neighbors.to_i
    @epsilon = epsilon.to_f
    @samples = []
    @fitnesses = []
    @mins = []
    @maxs = []
  end

  def fit(samples, fitnesses, mins:, maxs:)
    @samples = samples.map(&:dup)
    @fitnesses = fitnesses.map(&:to_f)
    @mins = mins.map(&:to_f)
    @maxs = maxs.map(&:to_f)
    self
  end

  def predict(point)
    raise 'Surrogate backend is not fitted' if @samples.empty?

    neighbors = nearest_neighbors(point)
    distances = neighbors.map { |neighbor| neighbor[:distance] }
    weights = distances.map { |distance| 1.0 / (distance + @epsilon) }
    weight_sum = weights.sum

    mean = neighbors.each_with_index.sum do |neighbor, idx|
      neighbor[:fitness] * weights[idx]
    end / [weight_sum, @epsilon].max

    variance = neighbors.each_with_index.sum do |neighbor, idx|
      centered = neighbor[:fitness] - mean
      weights[idx] * centered * centered
    end / [weight_sum, @epsilon].max

    sparsity = distances.sum / [distances.length, 1].max
    uncertainty = Math.sqrt([variance, 0.0].max) + sparsity

    {
      mean: mean,
      uncertainty: uncertainty,
      neighbor_count: neighbors.length,
      min_distance: distances.min || 0.0
    }
  end

  private

  def nearest_neighbors(point)
    distances = @samples.each_with_index.map do |sample, idx|
      {
        sample: sample,
        fitness: @fitnesses[idx],
        distance: normalized_distance(sample, point)
      }
    end

    distances.sort_by { |entry| entry[:distance] }.first([@k_neighbors, distances.length].min)
  end

  def normalized_distance(left, right)
    squared = left.each_with_index.sum do |value, idx|
      range = [@maxs[idx] - @mins[idx], @epsilon].max
      ((value.to_f - right[idx].to_f) / range) ** 2
    end
    Math.sqrt(squared)
  end
end
