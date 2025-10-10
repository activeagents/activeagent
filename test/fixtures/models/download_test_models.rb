#!/usr/bin/env ruby

require 'net/http'
require 'fileutils'
require 'open-uri'

# Download small ONNX models for testing
class TestModelDownloader
  TEST_MODELS = {
    # Small MobileNet model - only 13MB, perfect for testing
    "mobilenetv2-7.onnx" => {
      url: "https://github.com/onnx/models/raw/main/validated/vision/classification/mobilenet/model/mobilenetv2-7.onnx",
      size_mb: 13,
      description: "MobileNetV2 - Small vision model for testing"
    },
    # Tiny BERT model for text
    "bert-tiny.onnx" => {
      url: "https://huggingface.co/optimum/bert-tiny-random/resolve/main/onnx/model.onnx",
      size_mb: 17,
      description: "Tiny BERT model for text processing"
    },
    # Small GPT2 model
    "gpt2-tiny.onnx" => {
      url: "https://huggingface.co/onnx-community/gpt2/resolve/main/onnx/decoder_model.onnx",
      size_mb: 25,
      description: "Tiny GPT-2 model for text generation"
    }
  }
  
  def self.download_all
    models_dir = File.dirname(__FILE__)
    FileUtils.mkdir_p(models_dir)
    
    puts "📥 Downloading test models to #{models_dir}"
    
    TEST_MODELS.each do |filename, info|
      file_path = File.join(models_dir, filename)
      
      if File.exist?(file_path)
        puts "✅ #{filename} already exists (#{File.size(file_path) / 1024 / 1024}MB)"
        next
      end
      
      begin
        puts "⬇️  Downloading #{filename} (~#{info[:size_mb]}MB): #{info[:description]}"
        download_file(info[:url], file_path)
        puts "✅ Downloaded #{filename} (#{File.size(file_path) / 1024 / 1024}MB)"
      rescue => e
        puts "❌ Failed to download #{filename}: #{e.message}"
      end
    end
    
    # Create a simple test model symlink
    default_model = File.join(models_dir, "mobilenetv2-7.onnx")
    test_model = File.join(models_dir, "test_model.onnx")
    
    if File.exist?(default_model) && !File.exist?(test_model)
      File.symlink(default_model, test_model)
      puts "🔗 Created test_model.onnx symlink -> mobilenetv2-7.onnx"
    end
    
    puts "\n✅ Test models ready!"
  end
  
  def self.download_file(url, path)
    URI.open(url) do |remote_file|
      File.open(path, 'wb') do |local_file|
        local_file.write(remote_file.read)
      end
    end
  end
  
  # Check if we have at least one model
  def self.models_available?
    models_dir = File.dirname(__FILE__)
    TEST_MODELS.keys.any? { |filename| File.exist?(File.join(models_dir, filename)) }
  end
  
  # Get path to first available model
  def self.get_test_model_path
    models_dir = File.dirname(__FILE__)
    
    # First try test_model.onnx
    test_model = File.join(models_dir, "test_model.onnx")
    return test_model if File.exist?(test_model)
    
    # Then try any downloaded model
    TEST_MODELS.keys.each do |filename|
      path = File.join(models_dir, filename)
      return path if File.exist?(path)
    end
    
    nil
  end
end

# Run downloader if executed directly
if __FILE__ == $0
  TestModelDownloader.download_all
end