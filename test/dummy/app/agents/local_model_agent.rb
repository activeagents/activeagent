# frozen_string_literal: true

# Example agent demonstrating usage of local ONNX and Transformer models
# with various model loading strategies
class LocalModelAgent < ApplicationAgent
  # Example 1: Load model from HuggingFace Hub (auto-download and cache)
  def generate_with_huggingface_model
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "generation",
      "model" => "Xenova/gpt2",  # HuggingFace model identifier
      "model_source" => "huggingface",  # Explicitly specify source
      "cache_dir" => Rails.root.join("tmp", "models", "huggingface").to_s,  # Where to cache downloaded models
      "task" => "text-generation",
      "max_tokens" => params[:max_tokens] || 50,
      "temperature" => params[:temperature] || 0.7
    }
    
    prompt message: params[:message] || "The future of AI is"
  end
  
  # Example 2: Load model from Active Storage
  def generate_with_active_storage_model
    # Assume we have a Model record with an attached ONNX file
    model_record = Model.find(params[:model_id])
    
    # Download the model from Active Storage to a temp file
    model_path = Rails.root.join("tmp", "models", "active_storage", "#{model_record.id}.onnx")
    FileUtils.mkdir_p(File.dirname(model_path))
    
    File.open(model_path, "wb") do |file|
      file.write(model_record.onnx_file.download)
    end
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "custom",
      "model_source" => "active_storage",
      "model_path" => model_path.to_s,
      "model_metadata" => {
        "model_id" => model_record.id,
        "model_name" => model_record.name,
        "version" => model_record.version
      }
    }
    
    prompt message: params[:message]
  end
  
  # Example 3: Load model from local file system with explicit paths
  def generate_with_local_model
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "custom",
      "model_source" => "local",
      "model_path" => Rails.root.join("lib", "models", "onnx", params[:model_name] || "custom_model.onnx").to_s,
      "tokenizer_path" => Rails.root.join("lib", "models", "tokenizers", params[:tokenizer] || "tokenizer.json").to_s,
      "config_path" => Rails.root.join("lib", "models", "configs", params[:config] || "config.json").to_s
    }
    
    prompt message: params[:message]
  end
  
  # Example 4: Load model from URL (download on demand)
  def generate_with_url_model
    require "open-uri"
    
    model_url = params[:model_url] || "https://example.com/models/my_model.onnx"
    model_path = Rails.root.join("tmp", "models", "downloaded", Digest::MD5.hexdigest(model_url) + ".onnx")
    
    # Download if not cached
    unless File.exist?(model_path)
      FileUtils.mkdir_p(File.dirname(model_path))
      URI.open(model_url) do |remote_file|
        File.open(model_path, "wb") do |local_file|
          local_file.write(remote_file.read)
        end
      end
    end
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "custom",
      "model_source" => "url",
      "model_path" => model_path.to_s,
      "model_url" => model_url  # Store original URL for reference
    }
    
    prompt message: params[:message]
  end
  
  # Example 5: Using Transformers with HuggingFace auto-download
  def generate_with_transformers_auto
    self.class.generation_provider = {
      "service" => "Transformers",
      "model_type" => "generation",
      "model" => params[:model] || "microsoft/DialoGPT-small",  # Will auto-download from HuggingFace
      "model_source" => "huggingface",
      "cache_dir" => ENV["TRANSFORMERS_CACHE"] || Rails.root.join("tmp", "transformers_cache").to_s,
      "task" => "text-generation",
      "max_tokens" => params[:max_tokens] || 50,
      "temperature" => params[:temperature] || 0.7,
      "do_sample" => true,
      "device" => detect_device  # Auto-detect best device
    }
    
    prompt message: params[:message] || "Hello! How are you?"
  end
  
  # Example 6: Load pre-downloaded Transformers model from specific path
  def generate_with_local_transformers
    self.class.generation_provider = {
      "service" => "Transformers",
      "model_type" => "generation",
      "model" => Rails.root.join("lib", "models", "transformers", params[:model_dir] || "gpt2").to_s,
      "model_source" => "local",
      "task" => "text-generation",
      "expose_components" => true,  # Also expose model and tokenizer for advanced usage
      "device" => params[:device] || "cpu"
    }
    
    prompt message: params[:message]
  end
  
  # Example 7: Using embeddings with configurable model source
  def generate_embeddings
    model_config = case params[:source]
    when "huggingface"
      {
        "model" => params[:model] || "sentence-transformers/all-MiniLM-L6-v2",
        "model_source" => "huggingface",
        "cache_dir" => Rails.root.join("tmp", "embeddings_cache").to_s
      }
    when "local"
      {
        "model_path" => Rails.root.join("lib", "models", "embeddings", params[:model_file] || "embeddings.onnx").to_s,
        "model_source" => "local"
      }
    when "active_storage"
      embedding_model = EmbeddingModel.find(params[:model_id])
      {
        "model_path" => download_from_active_storage(embedding_model.file),
        "model_source" => "active_storage",
        "model_metadata" => { id: embedding_model.id, name: embedding_model.name }
      }
    else
      {
        "model" => "Xenova/all-MiniLM-L6-v2",
        "model_source" => "huggingface"
      }
    end
    
    self.class.generation_provider = {
      "service" => params[:use_onnx] ? "OnnxRuntime" : "Transformers",
      "model_type" => "embedding",
      "use_informers" => params[:use_informers] || true,
      **model_config
    }
    
    embed prompt: params[:text] || "Text to convert to embeddings"
  end
  
  # Example 8: Sentiment analysis with model management
  def analyze_sentiment_with_model_management
    # Check if model is already cached
    model_cache_key = "sentiment_model_#{params[:model_version] || 'latest'}"
    cached_model_path = Rails.cache.fetch(model_cache_key) do
      # Download and cache the model
      download_and_cache_model(
        model_name: "distilbert-base-uncased-finetuned-sst-2-english",
        version: params[:model_version] || "latest"
      )
    end
    
    self.class.generation_provider = {
      "service" => "Transformers",
      "model_type" => "sentiment",
      "model" => cached_model_path,
      "model_source" => "cached"
    }
    
    prompt message: params[:text] || "I love this product!"
  end
  
  # Example 9: Multi-model pipeline (e.g., translate then summarize)
  def translate_and_summarize
    # First, translate the text
    self.class.generation_provider = {
      "service" => "Transformers",
      "model_type" => "translation",
      "model" => "Helsinki-NLP/opus-mt-#{params[:source_lang] || 'en'}-#{params[:target_lang] || 'es'}",
      "model_source" => "huggingface",
      "source_language" => params[:source_lang] || "en",
      "target_language" => params[:target_lang] || "es"
    }
    
    translation_response = generate(prompt: params[:text])
    
    # Then summarize the translated text
    self.class.generation_provider = {
      "service" => "Transformers",
      "model_type" => "summarization",
      "model" => "facebook/bart-large-cnn",
      "model_source" => "huggingface",
      "max_length" => 150,
      "min_length" => 30
    }
    
    generate(prompt: translation_response.message.content)
  end
  
  private
  
  # Helper method to detect best available device
  def detect_device
    if params[:device]
      params[:device]
    elsif cuda_available?
      "cuda"
    elsif mps_available?
      "mps"  # Apple Silicon
    else
      "cpu"
    end
  end
  
  def cuda_available?
    # Check if CUDA is available (would need actual implementation)
    ENV["CUDA_VISIBLE_DEVICES"].present?
  end
  
  def mps_available?
    # Check if running on Apple Silicon with MPS support
    RUBY_PLATFORM.include?("darwin") && system("sysctl -n hw.optional.arm64", out: File::NULL)
  end
  
  def download_from_active_storage(attachment)
    temp_path = Rails.root.join("tmp", "models", "active_storage", "#{attachment.id}_#{attachment.filename}")
    FileUtils.mkdir_p(File.dirname(temp_path))
    
    File.open(temp_path, "wb") do |file|
      file.write(attachment.download)
    end
    
    temp_path.to_s
  end
  
  def download_and_cache_model(model_name:, version:)
    # Implementation to download and cache model
    # This would integrate with HuggingFace Hub API or your model registry
    cache_path = Rails.root.join("tmp", "model_cache", version, model_name.gsub("/", "_"))
    FileUtils.mkdir_p(cache_path)
    
    # Download model files if not present
    unless File.exist?(cache_path.join("config.json"))
      # Download model from HuggingFace or other source
      # This is a placeholder - actual implementation would use HuggingFace Hub API
    end
    
    cache_path.to_s
  end
end