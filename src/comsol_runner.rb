require 'thread'
require_relative 'utils'
require_relative 'problem'
require_relative 'runner'


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
problem = Problem.new
problem.params = params

threads = runners.map do |runner|
  Thread.new do
    # Создаем копию параметров для каждого потока
    thread_params = params.map { |p| Parameter.new(p.name, p.value) }
    thread_params.each do |param|
      param.value += rand(-0.1..0.1)
    end

    thread_problem = Problem.new
    thread_problem.params = thread_params

    # Создаем файл параметров для COMSOL
    paramfile = "params_#{runner.id}.txt"
    File.open(paramfile, 'w') do |file|
      thread_params.each do |param|
        file.puts "#{param.name} #{param.value}"
      end
    end

    result = thread_problem.solve_problem(methodcall, runner, paramfile)

    mutex.synchronize { results << { id: runner.id,
                                     params: thread_problem.params.map(&:to_s),
                                     output: result } }
  end
end

threads.each(&:join)
puts results
runners.each { |runner| FileUtils.remove_entry(runner.work_dir) }
