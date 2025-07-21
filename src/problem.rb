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
  def initialize(params, target_value)
    @params = params
    @target_value = target_value
  end

  # @param [ComsolRunner] runner
  def solve_problem(methodcall, runner)
    command = "comsolbatch -inputfile #{runner.file_name} -pname #{build_names} -plist \"#{build_values}\" -methodcall #{methodcall} -nosave"
    result = nil
    Dir.chdir(runner.work_dir) do
      IO.popen(command) do |io|
        io.each_line do |line|
          puts line
        end
      end
      output_path = File.join(runner.work_dir, runner.output_file)
      result = File.exist?(output_path) ? File.read(output_path).to_f : nil
    end
    result
  end

  def build_names
    @params.map(&:name).join(',')
  end

  def build_values
    @params.map(&:value).join(',')
  end

end