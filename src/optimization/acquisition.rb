# frozen_string_literal: true

# Функции acquisition для surrogate-driven оптимизации.
# Все score-методы возвращают значение, которое нужно МАКСИМИЗИРОВАТЬ.
class Acquisition
  DEFAULT_KAPPA = 2.0
  DEFAULT_XI = 0.01

  def initialize(mode: :expected_improvement, kappa: DEFAULT_KAPPA, xi: DEFAULT_XI)
    @mode = mode.to_sym
    @kappa = kappa.to_f
    @xi = xi.to_f
  end

  def score(prediction, best_fitness:)
    mean = prediction[:mean].to_f
    uncertainty = [prediction[:uncertainty].to_f, 1e-12].max

    case @mode
    when :expected_improvement, :ei
      expected_improvement(mean, uncertainty, best_fitness.to_f)
    when :lcb, :lower_confidence_bound
      lower_confidence_bound(mean, uncertainty)
    when :uncertainty
      uncertainty
    else
      expected_improvement(mean, uncertainty, best_fitness.to_f)
    end
  end

  private

  # Для задачи минимизации EI > 0, если ожидаем улучшение относительно best_fitness.
  def expected_improvement(mean, sigma, best_fitness)
    improvement = best_fitness - mean - @xi
    return [improvement, 0.0].max if sigma <= 1e-12

    z = improvement / sigma
    improvement * normal_cdf(z) + sigma * normal_pdf(z)
  end

  # Так как снаружи мы максимизируем score, возвращаем отрицание LCB.
  def lower_confidence_bound(mean, sigma)
    -(mean - @kappa * sigma)
  end

  def normal_pdf(x)
    Math.exp(-0.5 * x * x) / Math.sqrt(2.0 * Math::PI)
  end

  def normal_cdf(x)
    if Math.respond_to?(:erf)
      0.5 * (1.0 + Math.erf(x / Math.sqrt(2.0)))
    else
      # Аппроксимация Abramowitz and Stegun
      t = 1.0 / (1.0 + 0.2316419 * x.abs)
      d = 0.3989423 * Math.exp(-x * x / 2.0)
      prob = 1.0 - d * t * (0.3193815 + t * (-0.3565638 + t * (1.781478 + t * (-1.821256 + t * 1.330274))))
      x >= 0 ? prob : 1.0 - prob
    end
  end
end
