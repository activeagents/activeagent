require "test_helper"

class LocalModelsDocumentationTest < ActiveSupport::TestCase
  setup do
    @cache_dir = Rails.root.join("tmp", "test_models")
    FileUtils.mkdir_p(@cache_dir)
  end

  teardown do
    FileUtils.rm_rf(@cache_dir) if @cache_dir.exist?
  end

  # region test_onnx_configuration
  test "ONNX Runtime configuration example" do
    config = {
      "service" => "OnnxRuntime",
      "model_type" => "generation",
      "model" => "Xenova/gpt2",
      "task" => "text-generation",
      "max_tokens" => 50,
      "temperature" => 0.7
    }
    
    assert_equal "OnnxRuntime", config["service"]
    assert_equal "Xenova/gpt2", config["model"]
    
    doc_example_output(config, format: :ruby)
  end
  # endregion test_onnx_configuration

  # region test_transformers_configuration
  test "Transformers configuration example" do
    config = {
      "service" => "Transformers",
      "model_type" => "generation",
      "model" => "microsoft/DialoGPT-small",
      "task" => "text-generation",
      "device" => "mps",
      "max_tokens" => 50,
      "temperature" => 0.7
    }
    
    assert_equal "Transformers", config["service"]
    assert_equal "mps", config["device"]
    
    doc_example_output(config, format: :ruby)
  end
  # endregion test_transformers_configuration

  # region test_embedding_configuration
  test "Embedding model configuration example" do
    config = {
      "service" => "OnnxRuntime",
      "model_type" => "embedding",
      "model" => "Xenova/all-MiniLM-L6-v2",
      "use_informers" => true
    }
    
    assert_equal "embedding", config["model_type"]
    assert config["use_informers"]
    
    doc_example_output(config, format: :ruby)
  end
  # endregion test_embedding_configuration

  # region test_model_sources
  test "Model source configurations" do
    sources = [
      {
        name: "HuggingFace Auto-Download",
        config: {
          "service" => "OnnxRuntime",
          "model" => "Xenova/gpt2",
          "model_source" => "huggingface",
          "cache_dir" => Rails.root.join("tmp/models").to_s
        }
      },
      {
        name: "Local File System",
        config: {
          "service" => "OnnxRuntime",
          "model_type" => "custom",
          "model_source" => "local",
          "model_path" => "/path/to/model.onnx",
          "tokenizer_path" => "/path/to/tokenizer.json"
        }
      },
      {
        name: "URL Download",
        config: {
          "service" => "OnnxRuntime",
          "model_type" => "custom",
          "model_source" => "url",
          "model_url" => "https://example.com/models/my_model.onnx"
        }
      }
    ]
    
    sources.each do |source|
      assert source[:config]["service"].present?
      assert source[:config].key?("model") || source[:config].key?("model_path") || source[:config].key?("model_url")
    end
    
    doc_example_output(sources, format: :ruby)
  end
  # endregion test_model_sources

  # region test_device_detection
  test "Device detection logic" do
    device_detector = Class.new do
      def detect_device
        if cuda_available?
          "cuda"
        elsif mps_available?
          "mps"
        else
          "cpu"
        end
      end
      
      def cuda_available?
        # Check for NVIDIA GPU (simplified for testing)
        ENV['CUDA_VISIBLE_DEVICES'].present? || File.exist?('/usr/local/cuda')
      end
      
      def mps_available?
        # Check for Apple Silicon
        RUBY_PLATFORM.include?('darwin') && RUBY_PLATFORM.include?('arm64')
      end
    end
    
    detector = device_detector.new
    device = detector.detect_device
    
    assert %w[cuda mps cpu].include?(device)
    
    doc_example_output({ detected_device: device, platform: RUBY_PLATFORM }, format: :ruby)
  end
  # endregion test_device_detection

  # region test_rake_tasks
  test "Rake task commands" do
    commands = {
      list_models: "rake activeagent:models:list",
      download_huggingface: "rake activeagent:models:download[huggingface,Xenova/gpt2]",
      download_github: "rake activeagent:models:download[github,owner/repo/releases/download/v1.0/model.onnx]",
      setup_demo: "rake activeagent:models:setup_demo",
      cache_info: "rake activeagent:models:cache_info",
      clear_cache: "rake activeagent:models:clear_cache"
    }
    
    commands.each do |name, command|
      assert command.include?("activeagent:models")
    end
    
    doc_example_output(commands, format: :ruby)
  end
  # endregion test_rake_tasks

  # region test_batch_processing
  test "Batch processing example" do
    # Simulate batch processing without requiring ApplicationAgent
    texts = ["Hello world", "How are you?", "Testing embeddings"]
    
    # Example batch processing code structure
    batch_code = <<~RUBY
      class BatchEmbeddingAgent < ApplicationAgent
        def batch_embed
          texts = params[:texts]
          embeddings = texts.map do |text|
            embed(prompt: text)
          end
          embeddings
        end
      end
    RUBY
    
    # Simulate batch processing results
    results = texts.map do |text|
      { text: text, embedding_size: 384 }
    end
    
    assert_equal texts.length, results.length
    results.each do |result|
      assert_equal 384, result[:embedding_size]
    end
    
    doc_example_output({ code: batch_code, results: results }, format: :ruby)
  end
  # endregion test_batch_processing

  # region test_performance_settings
  test "Performance optimization settings" do
    performance_config = {
      cache_settings: {
        "ONNX_MODEL_CACHE" => Rails.root.join("storage/models/onnx").to_s,
        "TRANSFORMERS_CACHE" => Rails.root.join("storage/models/transformers").to_s
      },
      optimization_flags: {
        "use_quantized" => true,
        "batch_size" => 4,
        "num_threads" => 4,
        "enable_profiling" => false
      },
      memory_settings: {
        "max_model_size_mb" => 500,
        "clear_cache_after_use" => true,
        "preload_models" => ["onnx_embeddings", "transformers_sentiment"]
      }
    }
    
    assert performance_config[:cache_settings]["ONNX_MODEL_CACHE"].present?
    assert_equal 4, performance_config[:optimization_flags]["batch_size"]
    
    doc_example_output(performance_config, format: :ruby)
  end
  # endregion test_performance_settings

  # region test_apple_silicon_config
  test "Apple Silicon (M1/M2/M3) optimized configuration" do
    m1_config = {
      "service" => "Transformers",
      "model" => "distilgpt2",
      "device" => "mps",  # Metal Performance Shaders
      "task" => "text-generation",
      "max_tokens" => 50,
      "temperature" => 0.7,
      "optimization" => {
        "use_metal" => true,
        "enable_mixed_precision" => true,
        "batch_size" => 1
      }
    }
    
    assert_equal "mps", m1_config["device"]
    assert m1_config["optimization"]["use_metal"]
    
    doc_example_output(m1_config, format: :ruby)
  end
  # endregion test_apple_silicon_config

  # region test_model_preloading
  test "Model preloading on application start" do
    preload_config = <<~RUBY
      # config/initializers/local_models.rb
      Rails.application.config.after_initialize do
        ActiveAgent::ModelPreloader.preload_models([
          :onnx_embeddings,
          :transformers_sentiment,
          :gpt2_generation
        ])
      end
    RUBY
    
    assert preload_config.include?("ModelPreloader")
    assert preload_config.include?("after_initialize")
    
    doc_example_output({ initializer_code: preload_config }, format: :ruby)
  end
  # endregion test_model_preloading
end