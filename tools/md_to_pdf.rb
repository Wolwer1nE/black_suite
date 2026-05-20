#!/usr/bin/env ruby
# frozen_string_literal: true

require 'cgi'
require 'kramdown'
require 'kramdown-parser-gfm'
require 'optparse'
require 'pathname'
require 'tmpdir'

DEFAULT_BROWSER_CANDIDATES = [
  ENV['PDF_BROWSER_PATH'],
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe'
].freeze

DEFAULT_KATEX_VERSION = '0.16.11'

class SimpleMarkdownPreprocessor
  def initialize(markdown)
    @markdown = markdown
    @protected_blocks = {}
  end

  def call
    protected = protect_fenced_code_blocks(@markdown)
    protected = replace_display_math(protected)
    protected = replace_inline_math(protected)
    restore_fenced_code_blocks(protected)
  end

  private

  def protect_fenced_code_blocks(markdown)
    result = []
    buffer = []
    fence = nil
    fence_token = nil
    fence_index = 0

    markdown.each_line do |line|
      stripped = line.lstrip
      current_fence = stripped.start_with?('```') ? '```' : (stripped.start_with?('~~~') ? '~~~' : nil)

      if fence.nil? && current_fence
        fence = current_fence
        buffer << line
        next
      end

      if fence
        buffer << line
        if stripped.start_with?(fence)
          fence_token = "__CODE_FENCE_#{fence_index}__"
          @protected_blocks[fence_token] = buffer.join
          result << fence_token
          buffer = []
          fence = nil
          fence_index += 1
        end
        next
      end

      result << line
    end

    result.concat(buffer) unless buffer.empty?
    result.join
  end

  def restore_fenced_code_blocks(markdown)
    restored = markdown.dup
    @protected_blocks.each do |token, block|
      restored.gsub!(token, block)
    end
    restored
  end

  def replace_display_math(markdown)
    markdown.gsub(/\$\$(.+?)\$\$/m) do
      expression = Regexp.last_match(1).strip
      %(<div class="math-block">#{CGI.escapeHTML(expression)}</div>)
    end
  end

  def replace_inline_math(markdown)
    markdown.gsub(/(?<!\\)\$(?!\$)(.+?)(?<!\\)\$(?!\$)/) do
      expression = Regexp.last_match(1).strip
      %(<span class="math-inline">#{CGI.escapeHTML(expression)}</span>)
    end
  end
end

class BrowserMarkdownPdf
  def initialize(input_file:, output_file:, title:, page_size:, browser_path:, timeout_ms:)
    @input_file = input_file
    @output_file = output_file
    @title = title
    @page_size = page_size
    @browser_path = browser_path
    @timeout_ms = timeout_ms
  end

  def render
    markdown = @input_file.read(encoding: 'UTF-8')
    prepared_markdown = SimpleMarkdownPreprocessor.new(markdown).call
    body_html = Kramdown::Document.new(prepared_markdown, input: 'GFM').to_html

    Dir.mktmpdir('md_to_pdf') do |dir|
      html_path = File.join(dir, 'document.html')
      File.write(html_path, html_template(body_html), mode: 'w:UTF-8')
      print_html_to_pdf(html_path)
    end
  end

  private

  def html_template(body_html)
    katex_css = "https://cdn.jsdelivr.net/npm/katex@#{DEFAULT_KATEX_VERSION}/dist/katex.min.css"
    katex_js = "https://cdn.jsdelivr.net/npm/katex@#{DEFAULT_KATEX_VERSION}/dist/katex.min.js"
    katex_auto_render_js = "https://cdn.jsdelivr.net/npm/katex@#{DEFAULT_KATEX_VERSION}/dist/contrib/auto-render.min.js"

    <<~HTML
      <!DOCTYPE html>
      <html lang="ru">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{CGI.escapeHTML(@title)}</title>
        <link rel="stylesheet" href="#{katex_css}">
        <style>
          @page {
            size: #{@page_size};
            margin: 16mm 14mm 16mm 14mm;
          }

          :root {
            color-scheme: light;
          }

          body {
            font-family: "Segoe UI", Arial, sans-serif;
            color: #111827;
            line-height: 1.55;
            font-size: 12pt;
            margin: 0;
            background: #ffffff;
          }

          .doc-header {
            margin-bottom: 1.6rem;
            border-bottom: 1px solid #e5e7eb;
            padding-bottom: 0.8rem;
          }

          .doc-title {
            font-size: 24pt;
            font-weight: 700;
            margin: 0 0 0.25rem;
            color: #0f172a;
          }

          .doc-subtitle {
            font-size: 9pt;
            color: #6b7280;
            margin: 0;
            word-break: break-all;
          }

          h1, h2, h3, h4, h5, h6 {
            color: #0f172a;
            margin-top: 1.4em;
            margin-bottom: 0.5em;
            line-height: 1.25;
          }

          h1 { font-size: 22pt; }
          h2 { font-size: 18pt; }
          h3 { font-size: 15pt; }
          h4 { font-size: 13pt; }

          p, ul, ol, blockquote, pre, table {
            margin-top: 0;
            margin-bottom: 0.9em;
          }

          ul, ol {
            padding-left: 1.5rem;
          }

          code {
            font-family: Consolas, "Courier New", monospace;
            background: #f3f4f6;
            padding: 0.08rem 0.3rem;
            border-radius: 4px;
            font-size: 0.95em;
          }

          pre {
            background: #0f172a;
            color: #e5e7eb;
            padding: 0.85rem 1rem;
            border-radius: 10px;
            overflow-x: auto;
            white-space: pre-wrap;
          }

          pre code {
            background: transparent;
            color: inherit;
            padding: 0;
          }

          blockquote {
            border-left: 4px solid #93c5fd;
            margin-left: 0;
            padding: 0.35rem 0 0.35rem 1rem;
            color: #334155;
            background: #f8fafc;
          }

          table {
            width: 100%;
            border-collapse: collapse;
            font-size: 10.5pt;
          }

          th, td {
            border: 1px solid #d1d5db;
            padding: 0.45rem 0.55rem;
            text-align: left;
            vertical-align: top;
          }

          th {
            background: #f3f4f6;
          }

          hr {
            border: 0;
            border-top: 1px solid #d1d5db;
            margin: 1.3rem 0;
          }

          .math-inline,
          .math-block {
            visibility: hidden;
          }

          .math-block {
            display: block;
            margin: 1rem 0;
            text-align: center;
          }

          .katex-ready .math-inline,
          .katex-ready .math-block {
            visibility: visible;
          }
        </style>
        <script defer src="#{katex_js}"></script>
        <script defer src="#{katex_auto_render_js}"></script>
        <script>
          function renderMathNodes() {
            document.querySelectorAll('.math-inline').forEach(function(node) {
              katex.render(node.textContent, node, { throwOnError: false, displayMode: false });
            });

            document.querySelectorAll('.math-block').forEach(function(node) {
              katex.render(node.textContent, node, { throwOnError: false, displayMode: true });
            });

            document.body.classList.add('katex-ready');
            window.__PDF_READY__ = true;
          }

          window.__PDF_READY__ = false;
          window.addEventListener('load', function() {
            if (window.katex) {
              renderMathNodes();
            } else {
              document.body.classList.add('katex-ready');
              window.__PDF_READY__ = true;
            }
          });
        </script>
      </head>
      <body>
        <header class="doc-header">
          <h1 class="doc-title">#{CGI.escapeHTML(@title)}</h1>
          <p class="doc-subtitle">#{CGI.escapeHTML(@input_file.to_s)}</p>
        </header>
        <main>
          #{body_html}
        </main>
      </body>
      </html>
    HTML
  end

  def print_html_to_pdf(html_path)
    html_url = file_url_for(html_path)
    args = [
      '--headless=new',
      '--disable-gpu',
      '--allow-file-access-from-files',
      '--run-all-compositor-stages-before-draw',
      "--virtual-time-budget=#{@timeout_ms}",
      '--no-pdf-header-footer',
      "--print-to-pdf=#{@output_file}",
      html_url
    ]

    success = system(@browser_path, *args)
    raise 'Browser failed to generate PDF' unless success && File.exist?(@output_file)
  end

  def file_url_for(path)
    Pathname.new(path).expand_path.to_s.gsub('\\', '/').prepend('file:///')
  end
end

class SimplePrawnFallback
  def initialize(input_file:, output_file:, title:, page_size:)
    @input_file = input_file
    @output_file = output_file
    @title = title
    @page_size = page_size
  end

  def render
    require 'prawn'

    pdf = Prawn::Document.new(page_size: @page_size, margin: 48, info: { Title: @title })
    register_fonts(pdf)
    pdf.font 'DocSans'
    pdf.text @title, size: 22, style: :bold
    pdf.move_down 6
    pdf.text @input_file.to_s, size: 9, color: '6B7280'
    pdf.move_down 18
    pdf.text @input_file.read(encoding: 'UTF-8'), size: 10, leading: 2
    pdf.number_pages '<page>/<total>', at: [pdf.bounds.right - 50, 0], align: :right, size: 9
    pdf.render_file(@output_file.to_s)
  end

  private

  def register_fonts(pdf)
    windows_fonts_dir = File.join(ENV.fetch('WINDIR', 'C:/Windows'), 'Fonts')
    regular = find_first_existing_path([
      File.join(windows_fonts_dir, 'arial.ttf'),
      File.join(windows_fonts_dir, 'segoeui.ttf'),
      File.join(windows_fonts_dir, 'calibri.ttf')
    ])
    bold = find_first_existing_path([
      File.join(windows_fonts_dir, 'arialbd.ttf'),
      File.join(windows_fonts_dir, 'segoeuib.ttf'),
      File.join(windows_fonts_dir, 'calibrib.ttf')
    ]) || regular

    raise "Unable to locate Unicode fonts in #{windows_fonts_dir}" unless regular

    pdf.font_families.update(
      'DocSans' => {
        normal: regular,
        bold: bold,
        italic: regular,
        bold_italic: bold
      }
    )
  end

  def find_first_existing_path(paths)
    paths.find { |path| path && File.exist?(path) }
  end
end

options = {
  output: nil,
  title: nil,
  page_size: 'A4',
  engine: 'browser',
  browser: nil,
  timeout_ms: 5000
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: ruby tools/md_to_pdf.rb INPUT.md [options]'
  opts.separator ''
  opts.separator 'Engines:'
  opts.separator '  browser  Render Markdown to HTML with KaTeX and print via headless Edge/Chrome (default)'
  opts.separator '  simple   Fallback plain-text PDF renderer without math support'

  opts.on('-o', '--output FILE', 'Output PDF path') do |value|
    options[:output] = value
  end

  opts.on('-t', '--title TITLE', 'PDF title shown on the first page') do |value|
    options[:title] = value
  end

  opts.on('--page-size SIZE', 'PDF page size (default: A4)') do |value|
    options[:page_size] = value
  end

  opts.on('--engine NAME', 'Engine: browser (default) or simple') do |value|
    options[:engine] = value
  end

  opts.on('--browser PATH', 'Explicit path to Edge/Chrome executable for browser engine') do |value|
    options[:browser] = value
  end

  opts.on('--timeout MS', Integer, 'Virtual time budget in milliseconds for browser rendering') do |value|
    options[:timeout_ms] = value
  end

  opts.on('-h', '--help', 'Show help') do
    puts opts
    exit 0
  end
end

parser.parse!

input_path = ARGV.shift
abort(parser.to_s) unless input_path

input_file = Pathname.new(input_path).expand_path
abort("Markdown file not found: #{input_file}") unless input_file.file?

output_file = Pathname.new(options[:output] || input_file.sub_ext('.pdf')).expand_path
output_file.dirname.mkpath unless output_file.dirname.exist?
title = options[:title] || input_file.basename('.md').to_s.tr('_', ' ')

case options[:engine]
when 'browser'
  browser_path = options[:browser] || DEFAULT_BROWSER_CANDIDATES.find { |candidate| candidate && File.exist?(candidate) }
  abort('No supported browser found. Use --browser PATH or --engine simple.') unless browser_path

  BrowserMarkdownPdf.new(
    input_file: input_file,
    output_file: output_file,
    title: title,
    page_size: options[:page_size],
    browser_path: browser_path,
    timeout_ms: options[:timeout_ms]
  ).render
when 'simple'
  SimplePrawnFallback.new(
    input_file: input_file,
    output_file: output_file,
    title: title,
    page_size: options[:page_size]
  ).render
else
  abort("Unknown engine: #{options[:engine]}. Supported: browser, simple")
end

puts "PDF created: #{output_file}"
