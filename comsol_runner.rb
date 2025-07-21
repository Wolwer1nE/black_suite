require 'thread'
require_relative 'src/utils'
require_relative 'src/problem'
require_relative 'src/runner'


include Utils
infinity = 10e12
input_file = 'optMaterial.mph'
methodcall = 'target_function'
work_dir = 'D:/models'
output_file = 'demo_out.txt'
params = [Parameter.new('x0', -0.25),
          Parameter.new('y0', 0.25)]

runners = setup_clones(File.join(work_dir, input_file), 1)
            .map
            .with_index do |dir, index|
  ComsolRunner.new(input_file, dir, index, output_file)
end

results = []
mutex = Mutex.new
problem = Problem.new(params, infinity)
threads = runners.map do |runner|
  Thread.new do
    problem.params.each do |param|
      param.value += rand(-0.1..0.1)
    end
    result = problem.solve_problem(methodcall, runner)


    mutex.synchronize { results << { id: runner.id,
                                     params: problem.params.map(&:to_s),
                                     output: result } }
  end
end

threads.each(&:join)
puts results
runners.each { |runner| FileUtils.remove_entry(runner.work_dir) }
















