require 'fileutils'
require 'tmpdir'
module Utils
  def setup_clones(file_path, count)
    temp_dirs = []
    count.times do
      dir = Dir.mktmpdir
      FileUtils.cp(file_path, dir)
      temp_dirs << dir
    end
    temp_dirs
  end
end