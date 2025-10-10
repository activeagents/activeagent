require "test_helper"
require "active_agent/generation_provider/transformers_provider"

class TransformersProviderTest < ActiveSupport::TestCase
  setup do
    @config_generation = {
      "service" => "Transformers",
      "model_type" => "generation",
      "model" => "gpt2",
      "task" => "text-generation",
      "max_tokens" => 50,
      "temperature" => 0.7,
      "do_sample" => true
    }
    
    @config_embedding = {
      "service" => "Transformers",
      "model_type" => "embedding",
      "model" => "bert-base-uncased",
      "task" => "feature-extraction"
    }
    
    @config_sentiment = {
      "service" => "Transformers",
      "model_type" => "sentiment",
      "model" => "distilbert-base-uncased-finetuned-sst-2-english"
    }
    
    @config_summarization = {
      "service" => "Transformers",
      "model_type" => "summarization",
      "model" => "facebook/bart-large-cnn",
      "max_length" => 150,
      "min_length" => 30
    }
    
    @config_translation = {
      "service" => "Transformers",
      "model_type" => "translation",
      "model" => "Helsinki-NLP/opus-mt-en-es",
      "source_language" => "en",
      "target_language" => "es"
    }
    
    @config_qa = {
      "service" => "Transformers",
      "model_type" => "question-answering",
      "model" => "distilbert-base-cased-distilled-squad"
    }
  end

  test "initializes with generation configuration" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_generation)
    
    assert_equal "generation", provider.instance_variable_get(:@model_type)
    assert_equal "gpt2", provider.instance_variable_get(:@model_name)
    assert_equal "text-generation", provider.instance_variable_get(:@task)
  end

  test "initializes with embedding configuration" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_embedding)
    
    assert_equal "embedding", provider.instance_variable_get(:@model_type)
    assert_equal "bert-base-uncased", provider.instance_variable_get(:@model_name)
    assert_equal "feature-extraction", provider.instance_variable_get(:@task)
  end

  test "generates text with transformer model" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_generation)
    
    prompt = mock_prompt("The weather today is")
    response = provider.generate(prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal "assistant", response.message.role
    assert response.message.content.present?
  end

  test "generates embeddings with transformer model" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_embedding)
    
    prompt = mock_prompt("This is a test sentence for embedding.")
    response = provider.embed(prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal "assistant", response.message.role
    assert_kind_of Array, response.message.content
    assert response.message.content.all? { |val| val.is_a?(Numeric) }
  end

  test "analyzes sentiment with transformer model" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_sentiment)
    
    prompt = mock_prompt("I love this product! It's amazing!")
    response = provider.generate(prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal "assistant", response.message.role
    
    content = response.message.content
    assert content.is_a?(Hash) || content.is_a?(String)
  end

  test "summarizes text with transformer model" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_summarization)
    
    long_text = "This is a long article about artificial intelligence. " * 20
    prompt = mock_prompt(long_text)
    response = provider.generate(prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal "assistant", response.message.role
    assert response.message.content.present?
  end

  test "translates text with transformer model" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_translation)
    
    prompt = mock_prompt("Hello, how are you today?")
    response = provider.generate(prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal "assistant", response.message.role
    assert response.message.content.present?
  end

  test "answers questions with transformer model" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_qa)
    
    qa_content = {
      "question" => "What is the capital of France?",
      "context" => "France is a country in Europe. The capital of France is Paris."
    }
    prompt = mock_prompt(qa_content)
    response = provider.generate(prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal "assistant", response.message.role
    assert response.message.content.present?
  end

  test "infers task from model type" do
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_generation)
    
    assert_equal "text-generation", provider.send(:infer_task_from_model_type)
    
    provider.instance_variable_set(:@model_type, "embedding")
    assert_equal "feature-extraction", provider.send(:infer_task_from_model_type)
    
    provider.instance_variable_set(:@model_type, "sentiment")
    assert_equal "sentiment-analysis", provider.send(:infer_task_from_model_type)
  end

  test "builds generation arguments from config" do
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_generation)
    
    args = provider.send(:build_generation_args)
    
    assert_equal 50, args[:max_new_tokens]
    assert_equal 0.7, args[:temperature]
    assert_equal true, args[:do_sample]
  end

  test "extracts input text from various prompt types" do
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_generation)
    
    # Test with string
    text = provider.send(:extract_input_text, "Simple string")
    assert_equal "Simple string", text
    
    # Test with prompt object
    prompt = mock_prompt("Prompt content")
    text = provider.send(:extract_input_text, prompt)
    assert_equal "Prompt content", text
    
    # Test with multiple messages
    message1 = ActiveAgent::ActionPrompt::Message.new(content: "Hello", role: "user")
    message2 = ActiveAgent::ActionPrompt::Message.new(content: "Hi there", role: "assistant")
    prompt = ActiveAgent::ActionPrompt::Prompt.new
    prompt.messages = [message1, message2]
    
    text = provider.send(:extract_input_text, prompt)
    assert_equal "user: Hello\nassistant: Hi there", text
  end

  test "normalizes embedding format" do
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_embedding)
    
    # Test flat array
    embedding = [0.1, 0.2, 0.3]
    result = provider.send(:normalize_embedding, embedding)
    assert_equal embedding, result
    
    # Test nested array
    embedding = [[0.1, 0.2, 0.3]]
    result = provider.send(:normalize_embedding, embedding)
    assert_equal [0.1, 0.2, 0.3], result
    
    # Test hash with embeddings key
    embedding = { "embeddings" => [0.1, 0.2, 0.3] }
    result = provider.send(:normalize_embedding, embedding)
    assert_equal [0.1, 0.2, 0.3], result
  end

  test "extracts text from various result formats" do
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(@config_generation)
    
    # Test string result
    result = "Generated text"
    text = provider.send(:extract_text_from_result, result)
    assert_equal "Generated text", text
    
    # Test hash with generated_text
    result = { "generated_text" => "Generated content" }
    text = provider.send(:extract_text_from_result, result)
    assert_equal "Generated content", text
    
    # Test array of hashes
    result = [{ "generated_text" => "First result" }]
    text = provider.send(:extract_text_from_result, result)
    assert_equal "First result", text
  end

  test "handles device configuration" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    config = @config_generation.merge("device" => "cuda")
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(config)
    
    assert_not_nil provider.pipeline
  end

  test "exposes model and tokenizer when configured" do
    skip "Requires transformers-ruby gem" unless gem_available?("transformers-ruby")
    
    config = @config_generation.merge("expose_components" => true)
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(config)
    
    assert_not_nil provider.pipeline
    # Model and tokenizer would be available if the gem is properly installed
  end

  test "supports all generation parameters" do
    config = @config_generation.merge(
      "max_length" => 100,
      "min_length" => 10,
      "top_p" => 0.9,
      "top_k" => 50,
      "num_beams" => 4,
      "repetition_penalty" => 1.2,
      "length_penalty" => 1.0,
      "early_stopping" => true,
      "num_return_sequences" => 2
    )
    
    provider = ActiveAgent::GenerationProvider::TransformersProvider.new(config)
    args = provider.send(:build_generation_args)
    
    assert_equal 100, args[:max_length]
    assert_equal 10, args[:min_length]
    assert_equal 0.9, args[:top_p]
    assert_equal 50, args[:top_k]
    assert_equal 4, args[:num_beams]
    assert_equal 1.2, args[:repetition_penalty]
    assert_equal 1.0, args[:length_penalty]
    assert_equal true, args[:early_stopping]
    assert_equal 2, args[:num_return_sequences]
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