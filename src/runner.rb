class ComsolRunner
  attr_reader :work_dir, :id, :file_name, :output_file
  # @param [String] file_name
  # @param [String] work_dir
  # @param [Integer] id
  # @param [String] output_file
  def initialize(file_name, work_dir, id, output_file)
    @work_dir = work_dir
    @id = id
    @file_name = file_name
    @output_file = output_file
  end
end
