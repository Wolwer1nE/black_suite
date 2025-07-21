module Project
  def invisible_file?(file)
    return true if File.extname(file) == '.mph'
    return true if File.basename(file) == 'settings.json'

    false
  end

  def tree(path)
    Dir.entries(path).select { |e| e != '.' && e != '..' }.map do |entry|
      full_path = File.join(path, entry)
      if File.directory?(full_path)
        {
          name: entry,
          type: 'folder',
          children: tree(full_path)
        }
      elsif !invisible_file?(full_path)
        { name: entry, type: 'file' }
      else
        nil
      end
    end.compact
  end

end

