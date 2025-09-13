require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'open-uri'
require 'zip' if defined?(Zip)

namespace :activeagent do
  namespace :models do
    desc "Download models from HuggingFace or GitHub for local use"
    task :download, [:source, :model, :destination] => :environment do |t, args|
      # Default values
      args.with_defaults(
        source: 'huggingface',
        destination: Rails.root.join('storage', 'models')
      )
      
      unless args[:model]
        puts "Error: Model name/ID is required"
        puts "Usage: rails activeagent:models:download[huggingface,Xenova/gpt2]"
        puts "       rails activeagent:models:download[github,owner/repo/tag/model.onnx]"
        exit 1
      end
      
      downloader = ModelDownloader.new(
        source: args[:source],
        model: args[:model],
        destination: args[:destination]
      )
      
      downloader.download
    end
    
    desc "List available pre-configured models"
    task :list => :environment do
      puts "\n" + "="*60
      puts "Available Pre-configured Models".center(60)
      puts "="*60 + "\n\n"
      
      puts "ONNX Runtime Models (HuggingFace):"
      puts "-" * 40
      onnx_models.each do |model|
        puts "  • #{model[:name].ljust(30)} - #{model[:description]}"
      end
      
      puts "\nTransformers Models:"
      puts "-" * 40
      transformer_models.each do |model|
        puts "  • #{model[:name].ljust(30)} - #{model[:description]}"
      end
      
      puts "\n" + "="*60
      puts "\nUsage: rails activeagent:models:download[huggingface,MODEL_NAME]"
      puts "Example: rails activeagent:models:download[huggingface,Xenova/gpt2]"
    end
    
    desc "Download recommended models for demos"
    task :setup_demo => :environment do
      puts "Setting up demo models..."
      
      demo_models = [
        { source: 'huggingface', model: 'Xenova/gpt2', type: 'ONNX text generation' },
        { source: 'huggingface', model: 'Xenova/all-MiniLM-L6-v2', type: 'ONNX embeddings' },
        { source: 'huggingface', model: 'distilbert-base-uncased-finetuned-sst-2-english', type: 'Sentiment analysis' }
      ]
      
      demo_models.each do |config|
        puts "\nDownloading #{config[:type]} model: #{config[:model]}"
        Rake::Task['activeagent:models:download'].execute(
          source: config[:source],
          model: config[:model]
        )
      end
      
      puts "\n✅ Demo models setup complete!"
    end
    
    desc "Clear model cache"
    task :clear_cache => :environment do
      cache_dir = Rails.root.join('storage', 'models')
      
      if Dir.exist?(cache_dir)
        puts "Clearing model cache at #{cache_dir}..."
        FileUtils.rm_rf(Dir.glob("#{cache_dir}/*"))
        puts "✅ Cache cleared"
      else
        puts "Cache directory does not exist"
      end
    end
    
    desc "Show model cache info"
    task :cache_info => :environment do
      cache_dir = Rails.root.join('storage', 'models')
      
      if Dir.exist?(cache_dir)
        total_size = 0
        model_count = 0
        
        puts "\nModel Cache Information:"
        puts "=" * 50
        puts "Cache location: #{cache_dir}"
        puts "-" * 50
        
        Dir.glob("#{cache_dir}/**/*").select { |f| File.file?(f) }.each do |file|
          size = File.size(file)
          total_size += size
          model_count += 1 if file.end_with?('.onnx', '.bin', '.safetensors')
          
          relative_path = file.sub("#{cache_dir}/", '')
          puts "  #{relative_path.ljust(40)} #{format_size(size)}"
        end
        
        puts "-" * 50
        puts "Total models: #{model_count}"
        puts "Total size: #{format_size(total_size)}"
        puts "=" * 50
      else
        puts "Cache directory does not exist"
      end
    end
    
    private
    
    def onnx_models
      [
        { name: 'Xenova/gpt2', description: 'GPT-2 text generation' },
        { name: 'Xenova/distilgpt2', description: 'Smaller GPT-2 variant' },
        { name: 'Xenova/all-MiniLM-L6-v2', description: 'Sentence embeddings' },
        { name: 'Xenova/t5-small', description: 'Text-to-text generation' },
        { name: 'Xenova/bert-base-uncased', description: 'BERT embeddings' }
      ]
    end
    
    def transformer_models
      [
        { name: 'gpt2', description: 'OpenAI GPT-2' },
        { name: 'distilgpt2', description: 'Distilled GPT-2' },
        { name: 'microsoft/DialoGPT-small', description: 'Conversational AI' },
        { name: 'bert-base-uncased', description: 'BERT base model' },
        { name: 'distilbert-base-uncased', description: 'Distilled BERT' },
        { name: 'sentence-transformers/all-MiniLM-L6-v2', description: 'Sentence embeddings' }
      ]
    end
    
    def format_size(bytes)
      units = ['B', 'KB', 'MB', 'GB']
      unit_index = 0
      size = bytes.to_f
      
      while size >= 1024 && unit_index < units.length - 1
        size /= 1024
        unit_index += 1
      end
      
      "%.2f %s" % [size, units[unit_index]]
    end
  end
end

# Model downloader class
class ModelDownloader
  attr_reader :source, :model, :destination
  
  def initialize(source:, model:, destination:)
    @source = source.to_s.downcase
    @model = model
    @destination = destination.to_s
    
    FileUtils.mkdir_p(@destination)
  end
  
  def download
    case @source
    when 'huggingface', 'hf'
      download_from_huggingface
    when 'github', 'gh'
      download_from_github
    when 'url'
      download_from_url
    else
      puts "Unknown source: #{@source}"
      puts "Supported sources: huggingface, github, url"
    end
  end
  
  private
  
  def download_from_huggingface
    puts "Downloading from HuggingFace: #{@model}"
    
    # Parse model ID (format: namespace/model-name)
    parts = @model.split('/')
    if parts.length != 2
      puts "Invalid HuggingFace model format. Expected: namespace/model-name"
      return
    end
    
    namespace, model_name = parts
    
    # Common ONNX model files to try downloading
    model_files = [
      'onnx/model.onnx',
      'onnx/model_quantized.onnx',
      'model.onnx',
      'pytorch_model.bin',
      'model.safetensors'
    ]
    
    config_files = [
      'config.json',
      'tokenizer.json',
      'tokenizer_config.json'
    ]
    
    base_url = "https://huggingface.co/#{@model}/resolve/main"
    model_dir = File.join(@destination, 'huggingface', namespace, model_name)
    FileUtils.mkdir_p(model_dir)
    
    downloaded_files = []
    
    # Download configuration files
    config_files.each do |file|
      url = "#{base_url}/#{file}"
      dest_file = File.join(model_dir, file)
      
      if download_file(url, dest_file)
        downloaded_files << file
      end
    end
    
    # Try to download model files
    model_downloaded = false
    model_files.each do |file|
      url = "#{base_url}/#{file}"
      dest_file = File.join(model_dir, file.split('/').last)
      
      if download_file(url, dest_file)
        downloaded_files << file
        model_downloaded = true
        break  # Stop after first successful model download
      end
    end
    
    if model_downloaded
      puts "\n✅ Successfully downloaded #{@model}"
      puts "Location: #{model_dir}"
      puts "Files: #{downloaded_files.join(', ')}"
    else
      puts "\n❌ Could not download model files for #{@model}"
      puts "This model might require manual download or different file structure"
    end
  end
  
  def download_from_github
    puts "Downloading from GitHub: #{@model}"
    
    # Parse GitHub path (format: owner/repo/releases/tag/filename)
    # or owner/repo/blob/branch/path/to/file
    parts = @model.split('/')
    
    if parts.length < 4
      puts "Invalid GitHub path. Expected format:"
      puts "  owner/repo/releases/download/tag/filename"
      puts "  owner/repo/raw/branch/path/to/file"
      return
    end
    
    owner = parts[0]
    repo = parts[1]
    
    if parts[2] == 'releases' && parts[3] == 'download'
      # GitHub releases URL
      tag = parts[4]
      filename = parts[5..-1].join('/')
      url = "https://github.com/#{owner}/#{repo}/releases/download/#{tag}/#{filename}"
    else
      # Raw GitHub content
      branch = parts[3] || 'main'
      filepath = parts[4..-1].join('/')
      url = "https://raw.githubusercontent.com/#{owner}/#{repo}/#{branch}/#{filepath}"
    end
    
    model_dir = File.join(@destination, 'github', owner, repo)
    FileUtils.mkdir_p(model_dir)
    
    filename = File.basename(url)
    dest_file = File.join(model_dir, filename)
    
    if download_file(url, dest_file)
      puts "\n✅ Successfully downloaded from GitHub"
      puts "Location: #{dest_file}"
    else
      puts "\n❌ Failed to download from GitHub"
    end
  end
  
  def download_from_url
    puts "Downloading from URL: #{@model}"
    
    filename = File.basename(@model)
    model_dir = File.join(@destination, 'downloads')
    FileUtils.mkdir_p(model_dir)
    
    dest_file = File.join(model_dir, filename)
    
    if download_file(@model, dest_file)
      puts "\n✅ Successfully downloaded"
      puts "Location: #{dest_file}"
    else
      puts "\n❌ Failed to download from URL"
    end
  end
  
  def download_file(url, destination)
    return false if File.exist?(destination) && !confirm_overwrite(destination)
    
    begin
      print "Downloading #{File.basename(destination)}... "
      
      URI.open(url) do |remote_file|
        File.open(destination, 'wb') do |local_file|
          local_file.write(remote_file.read)
        end
      end
      
      puts "✓ (#{format_size(File.size(destination))})"
      true
    rescue OpenURI::HTTPError => e
      puts "✗ (HTTP #{e.message.split(' ').first})"
      false
    rescue => e
      puts "✗ (#{e.message})"
      false
    end
  end
  
  def confirm_overwrite(file)
    print "File #{File.basename(file)} already exists. Overwrite? (y/n): "
    response = STDIN.gets.chomp.downcase
    response == 'y' || response == 'yes'
  end
  
  def format_size(bytes)
    units = ['B', 'KB', 'MB', 'GB']
    unit_index = 0
    size = bytes.to_f
    
    while size >= 1024 && unit_index < units.length - 1
      size /= 1024
      unit_index += 1
    end
    
    "%.2f %s" % [size, units[unit_index]]
  end
end
