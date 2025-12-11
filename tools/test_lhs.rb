require_relative 'lhs'

def assert(cond, msg=nil)
  unless cond
    raise "Assertion failed" + (msg ? ": #{msg}" : "")
  end
end

puts "Running LHS tests..."

# Test 1: determinism with same RNG seed
s1 = LHS.sample(10, 3, [0,0,0], [1,10,100], rng: Random.new(12345))
s2 = LHS.sample(10, 3, [0,0,0], [1,10,100], rng: Random.new(12345))
assert(s1 == s2, "samples should be identical with same RNG seed")

# Test 2: bounds honored
lower = [0.0, -5.0, 10.0]
upper = [1.0, 5.0, 20.0]
s = LHS.sample(50, 3, lower, upper, rng: Random.new(42))
50.times do |i|
  3.times do |d|
    v = s[i][d]
    assert(v >= lower[d] - 1e-12, "value < lower bound for dim #{d}: #{v} < #{lower[d]}")
    assert(v <= upper[d] + 1e-12, "value > upper bound for dim #{d}: #{v} > #{upper[d]}")
  end
end

# Test 3: uniqueness of strata per dimension
n = 20
lower = Array.new(3, 10.0)
upper = [20.0, 30.0, 40.0]
s = LHS.sample(n, 3, lower, upper, rng: Random.new(7))
3.times do |d|
  range = upper[d] - lower[d]
  indices = s.map do |pt|
    # compute which stratum index the sample falls into: floor(((v - lower)/range)*n)
    idx = (((pt[d] - lower[d]) / range) * n).floor
    idx = 0 if idx < 0
    idx = n-1 if idx >= n
    idx
  end
  assert(indices.uniq.length == n, "not all strata used in dim #{d}: #{indices.uniq.length} != #{n}")
  assert(indices.sort == (0...n).to_a, "strata indices mismatch for dim #{d}")
end

# Test 4: invalid args
began = false
begin
  LHS.sample(0, 1)
rescue ArgumentError
  began = true
end
assert(began, "expected ArgumentError for n=0")

puts "All LHS tests passed"

