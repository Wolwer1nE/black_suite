class Parameter
  attr_accessor :name, :value

  # @param [String] name
  # @param [Numeric] value
  def initialize(name, value)
    @name = name
    @value = value
  end

  def to_s
    "#{@name} = #{@value}"
  end
end

class Problem
  attr_accessor :params, :target_value

  # @param [Array] params
  # @param [Numeric] target_value
  def initialize()

  end

  # @param [ComsolRunner] runner
  def solve_problem(methodcall, runner, paramfile, silent_mode: false)
    command = "comsolbatch -inputfile #{runner.file_name} -paramfile #{paramfile} -methodcall #{methodcall} -nosave"
    result = nil
    Dir.chdir(runner.work_dir) do
      IO.popen(command) do |io|
        io.each_line do |line|
          puts "\e[34m#{line}\e[0m" unless silent_mode
        end
      end
      output_path = File.join(runner.work_dir, runner.output_file)
      result = File.exist?(output_path) ? File.read(output_path).to_f : nil
    end
    result
  end
end