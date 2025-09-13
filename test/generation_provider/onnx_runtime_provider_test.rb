require "test_helper"
require "active_agent/generation_provider/onnx_runtime_provider"

class OnnxRuntimeProviderTest < ActiveSupport::TestCase
  setup do
    @config_generation = {
      "service" => "OnnxRuntime",
      "model_type" => "generation",
      "model" => "Xenova/gpt2",
      "task" => "text-generation",
      "max_tokens" => 50,
      "temperature" => 0.7
    }
    
    @config_embedding = {
      "service" => "OnnxRuntime",
      "model_type" => "embedding",
      "model" => "Xenova/all-MiniLM-L6-v2",
      "use_informers" => true
    }
    
    @config_custom_onnx = {
      "service" => "OnnxRuntime",
      "model_type" => "custom",
      "model_path" => "/path/to/model.onnx",
      "tokenizer_path" => "/path/to/tokenizer.json"
    }
  end

  test "initializes with generation configuration" do
    skip "Requires informers gem" unless gem_available?("informers")
    
    provider = ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(@config_generation)
    
    assert_equal "generation", provider.instance_variable_get(:@model_type)
    assert_equal "Xenova/gpt2", provider.instance_variable_get(:@model_name)
  end

  test "initializes with embedding configuration" do
    skip "Requires informers gem" unless gem_available?("informers")
    
    provider = ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(@config_embedding)
    
    assert_equal "embedding", provider.instance_variable_get(:@model_type)
    assert_equal "Xenova/all-MiniLM-L6-v2", provider.instance_variable_get(:@model_name)
  end

  test "generates text with informers model" do
    skip "Requires informers gem" unless gem_available?("informers")
    
    provider = ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(@config_generation)
    
    prompt = mock_prompt("Hello, how are you?")
    response = provider.generate(prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal "assistant", response.message.role
    assert response.message.content.present?
  end

  test "generates embeddings with informers model" do
    skip "Requires informers gem" unless gem_available?("informers")
    
    provider = ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(@config_embedding)
    
    prompt = mock_prompt("This is a test sentence for embedding.")
    response = provider.embed(prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal "assistant", response.message.role
    assert_kind_of Array, response.message.content
    assert response.message.content.all? { |val| val.is_a?(Numeric) }
  end

  test "handles custom ONNX model configuration" do
    skip "Requires onnxruntime gem" unless gem_available?("onnxruntime")
    skip "Requires actual ONNX model file" unless File.exist?(@config_custom_onnx["model_path"])
    
    provider = ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(@config_custom_onnx)
    
    assert_equal "custom", provider.instance_variable_get(:@model_type)
    assert_not_nil provider.onnx_model
  end

  test "raises error for unsupported model type" do
    config = @config_generation.merge("model_type" => "unsupported")
    
    assert_raises(ArgumentError) do
      ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(config)
    end
  end

  test "builds generation options from config" do
    provider = ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(@config_generation)
    
    options = provider.send(:build_generation_options)
    
    assert_equal 50, options[:max_new_tokens]
    assert_equal 0.7, options[:temperature]
  end

  test "extracts input text from various prompt types" do
    provider = ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(@config_generation)
    
    # Test with string
    text = provider.send(:extract_input_text, "Simple string")
    assert_equal "Simple string", text
    
    # Test with prompt object
    prompt = mock_prompt("Prompt content")
    text = provider.send(:extract_input_text, prompt)
    assert_equal "Prompt content", text
  end

  test "handles embedding response correctly" do
    provider = ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(@config_embedding)
    
    embedding = [0.1, 0.2, 0.3, 0.4, 0.5]
    prompt = mock_prompt("Test")
    
    response = provider.send(:handle_embedding_response, embedding, "Test")
    
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal embedding, response.message.content
    assert_equal({ embedding: embedding }, response.raw_response)
  end

  test "supports different informers tasks" do
    skip "Requires informers gem" unless gem_available?("informers")
    
    tasks = ["text-generation", "text2text-generation", "question-answering", "summarization"]
    
    tasks.each do |task|
      config = @config_generation.merge("task" => task)
      provider = ActiveAgent::GenerationProvider::OnnxRuntimeProvider.new(config)
      
      assert_not_nil provider.informer
    end
  end

  private

  def mock_prompt(content)
    message = ActiveAgent::ActionPrompt::Message.new(content: content, role: "user")
    prompt = ActiveAgent::ActionPrompt::Prompt.new
    prompt.message = message
    prompt.messages = [message]
    prompt
  end

  def gem_available?(gem_name)
    require gem_name
    true
  rescue LoadError
    false
  end
end