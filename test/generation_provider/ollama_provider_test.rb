require "test_helper"
require "openai"
require "active_agent/action_prompt"
require "active_agent/generation_provider/ollama_provider"

class OllamaProviderTest < ActiveSupport::TestCase
  setup do
    @config = {
      "service" => "Ollama",
      "model" => "gemma3:latest",
      "host" => "http://localhost:11434",
      "api_version" => "v1",
      "embedding_model" => "nomic-embed-text"
    }
    @provider = ActiveAgent::GenerationProvider::OllamaProvider.new(@config)

    @prompt = ActiveAgent::ActionPrompt::Prompt.new(
      message: ActiveAgent::ActionPrompt::Message.new(content: "Test content for embedding"),
      instructions: "You are a test agent"
    )
  end

  test "initializes with correct configuration" do
    assert_equal "gemma3:latest", @provider.instance_variable_get(:@model_name)
    assert_equal "http://localhost:11434", @provider.instance_variable_get(:@host)
    assert_equal "v1", @provider.instance_variable_get(:@api_version)

    client = @provider.instance_variable_get(:@client)
    assert_instance_of OpenAI::Client, client
  end

  test "uses default values when config values not provided" do
    minimal_config = {
      "service" => "Ollama",
      "model" => "llama2:latest"
    }
    provider = ActiveAgent::GenerationProvider::OllamaProvider.new(minimal_config)

    assert_equal "http://localhost:11434", provider.instance_variable_get(:@host)
    assert_equal "v1", provider.instance_variable_get(:@api_version)
  end

  test "embeddings_parameters returns correct structure" do
    params = @provider.send(:embeddings_parameters, input: "Test text", model: "nomic-embed-text")

    assert_equal "nomic-embed-text", params[:model]
    assert_equal "Test text", params[:input]
  end

  test "embeddings_parameters uses config embedding_model when available" do
    params = @provider.send(:embeddings_parameters, input: "Test text")

    assert_equal "nomic-embed-text", params[:model]
    assert_equal "Test text", params[:input]
  end

  test "embeddings_parameters uses prompt message content by default" do
    @provider.instance_variable_set(:@prompt, @prompt)
    params = @provider.send(:embeddings_parameters)

    assert_equal "nomic-embed-text", params[:model]
    assert_equal "Test content for embedding", params[:input]
  end

  test "embeddings_response creates proper response object" do
    mock_response = {
      "embedding" => [ 0.1, 0.2, 0.3, 0.4, 0.5 ],
      "model" => "nomic-embed-text",
      "created" => 1234567890
    }

    request_params = {
      model: "nomic-embed-text",
      input: "Test text"
    }

    @provider.instance_variable_set(:@prompt, @prompt)
    response = @provider.send(:embeddings_response, mock_response, request_params)

    assert_instance_of ActiveAgent::GenerationProvider::Response, response
    assert_equal @prompt, response.prompt
    assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
    assert_equal [ 0.1, 0.2, 0.3, 0.4, 0.5 ], response.message.content
    assert_equal "assistant", response.message.role
    assert_equal mock_response, response.raw_response
    assert_equal request_params, response.raw_request
  end

  test "embed method works with Ollama provider" do
    VCR.use_cassette("ollama_provider_embed") do
      # region ollama_provider_embed
      provider = ActiveAgent::GenerationProvider::OllamaProvider.new(@config)
      prompt = ActiveAgent::ActionPrompt::Prompt.new(
        message: ActiveAgent::ActionPrompt::Message.new(content: "Generate an embedding for this text"),
        instructions: "You are an embedding test agent"
      )

      response = provider.embed(prompt)
      # endregion ollama_provider_embed

      assert_not_nil response
      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_not_nil response.message.content
      assert_kind_of Array, response.message.content
      assert response.message.content.all? { |val| val.is_a?(Numeric) }

      doc_example_output(response)
    rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout => e
      skip "Ollama is not running locally: #{e.message}"
    end
  end

  test "embed method provides helpful error when Ollama not running" do
    # Configure with a bad port to simulate Ollama not running
    # Disable VCR for this test to allow actual connection failure
    VCR.turn_off!
    WebMock.allow_net_connect!

    bad_config = @config.merge("host" => "http://localhost:99999")
    provider = ActiveAgent::GenerationProvider::OllamaProvider.new(bad_config)
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      message: ActiveAgent::ActionPrompt::Message.new(content: "Test embedding"),
      instructions: "Test agent"
    )

    error = assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
      provider.embed(prompt)
    end

    assert_match(/Unable to connect to Ollama at http:\/\/localhost:99999/, error.message)
    assert_match(/Please ensure Ollama is running/, error.message)
    assert_match(/ollama serve/, error.message)
  ensure
    VCR.turn_on!
    WebMock.disable_net_connect!
  end

  test "inherits from OpenAIProvider" do
    assert ActiveAgent::GenerationProvider::OllamaProvider < ActiveAgent::GenerationProvider::OpenAIProvider
  end

  test "overrides embeddings methods from parent class" do
    # Verify that OllamaProvider has its own implementation of these methods
    assert @provider.respond_to?(:embeddings_parameters, true)
    assert @provider.respond_to?(:embeddings_response, true)

    # Verify the methods are defined in OllamaProvider, not just inherited
    ollama_methods = ActiveAgent::GenerationProvider::OllamaProvider.instance_methods(false)
    assert_includes ollama_methods, :embeddings_parameters
    assert_includes ollama_methods, :embeddings_response
  end

  test "handles Ollama-specific embedding format" do
    # Test native Ollama format
    ollama_response = {
      "embedding" => [ 0.1, 0.2, 0.3 ],
      "model" => "nomic-embed-text"
    }

    @provider.instance_variable_set(:@prompt, @prompt)
    response = @provider.send(:embeddings_response, ollama_response)

    assert_equal [ 0.1, 0.2, 0.3 ], response.message.content
  end

  test "handles OpenAI-compatible embedding format from Ollama" do
    # Test OpenAI-compatible format that newer Ollama versions return
    openai_format_response = {
      "data" => [
        {
          "embedding" => [ 0.4, 0.5, 0.6 ],
          "object" => "embedding"
        }
      ],
      "model" => "nomic-embed-text",
      "object" => "list"
    }

    @provider.instance_variable_set(:@prompt, @prompt)
    response = @provider.send(:embeddings_response, openai_format_response)

    assert_equal [ 0.4, 0.5, 0.6 ], response.message.content
  end
end
