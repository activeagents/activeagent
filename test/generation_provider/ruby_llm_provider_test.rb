require "test_helper"
require "active_agent/action_prompt/prompt"
require "active_agent/action_prompt/message"

# Require the provider class if the gem is available
begin
  require "ruby_llm"
  require "active_agent/generation_provider/ruby_llm_provider"
rescue LoadError
  # Gem not available, tests will skip
end

# Test for RubyLLM Provider gem loading and configuration
class RubyLLMProviderTest < ActiveAgentTestCase
  # Test the gem load rescue block
  test "gem load rescue block provides correct error message" do
    # Since we can't easily simulate the gem not being available without complex mocking,
    # we'll test that the error message is correct by creating a minimal reproduction
    expected_message = "The 'ruby_llm >= 0.1.0' gem is required for RubyLLMProvider. Please add it to your Gemfile and run `bundle install`."

    # Verify the rescue block pattern exists in the source code
    provider_file_path = File.join(Rails.root, "../../lib/active_agent/generation_provider/ruby_llm_provider.rb")
    provider_source = File.read(provider_file_path)

    assert_includes provider_source, "begin"
    assert_includes provider_source, 'gem "ruby_llm"'
    assert_includes provider_source, 'require "ruby_llm"'
    assert_includes provider_source, "rescue LoadError"
    assert_includes provider_source, expected_message

    # Test the actual error by creating a minimal scenario
    test_code = <<~RUBY
      begin
        gem "nonexistent-ruby-llm-gem"
        require "nonexistent-ruby-llm-gem"
      rescue LoadError
        raise LoadError, "#{expected_message}"
      end
    RUBY

    error = assert_raises(LoadError) do
      eval(test_code)
    end

    assert_equal expected_message, error.message
  end

  test "loads successfully when ruby_llm gem is available" do
    # Skip this test if the gem is not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    # This test ensures the provider loads correctly when the gem is present
    assert_nothing_raised do
      require "active_agent/generation_provider/ruby_llm_provider"
    end

    # Verify the class exists and can be instantiated with valid config
    assert defined?(ActiveAgent::GenerationProvider::RubyLLMProvider)

    config = {
      "service" => "RubyLLM",
      "openai_api_key" => "test-key",
      "model" => "gpt-4o-mini",
      "default_provider" => "openai"
    }

    assert_nothing_raised do
      ActiveAgent::GenerationProvider::RubyLLMProvider.new(config)
    end
  end

  # Test configuration loading and presence
  test "loads configuration from active_agent.yml when present" do
    # Mock a configuration
    mock_config = {
      "test" => {
        "ruby_llm" => {
          "service" => "RubyLLM",
          "openai_api_key" => "test-openai-key",
          "anthropic_api_key" => "test-anthropic-key",
          "default_provider" => "openai",
          "model" => "gpt-4o-mini",
          "temperature" => 0.7,
          "enable_image_generation" => false
        }
      }
    }

    ActiveAgent.instance_variable_set(:@config, mock_config)

    # Set Rails environment for testing
    rails_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "test"

    config = ApplicationAgent.configuration(:ruby_llm)

    assert_equal "RubyLLM", config.config["service"]
    assert_equal "test-openai-key", config.config["openai_api_key"]
    assert_equal "test-anthropic-key", config.config["anthropic_api_key"]
    assert_equal "openai", config.config["default_provider"]
    assert_equal "gpt-4o-mini", config.config["model"]
    assert_equal 0.7, config.config["temperature"]
    assert_equal false, config.config["enable_image_generation"]

    # Restore original environment
    ENV["RAILS_ENV"] = rails_env
  end

  # Test provider initialization with different configurations
  test "initializes with multiple provider API keys" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    config = {
      "service" => "RubyLLM",
      "openai_api_key" => "openai-test-key",
      "anthropic_api_key" => "anthropic-test-key",
      "gemini_api_key" => "gemini-test-key",
      "default_provider" => "anthropic",
      "model" => "claude-3-sonnet",
      "timeout" => 30,
      "max_retries" => 3
    }

    provider = ActiveAgent::GenerationProvider::RubyLLMProvider.new(config)
    
    assert_not_nil provider
    assert_equal "claude-3-sonnet", provider.instance_variable_get(:@model_name)
  end

  # Test image generation capability
  test "sets image generation flag when enabled" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    config = {
      "service" => "RubyLLM",
      "openai_api_key" => "test-key",
      "enable_image_generation" => true
    }

    provider = ActiveAgent::GenerationProvider::RubyLLMProvider.new(config)
    
    # Check that image generation is enabled
    assert_equal true, provider.instance_variable_get(:@enable_image_generation)
  end

  test "does not set image generation flag when disabled" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    config = {
      "service" => "RubyLLM",
      "openai_api_key" => "test-key",
      "enable_image_generation" => false
    }

    provider = ActiveAgent::GenerationProvider::RubyLLMProvider.new(config)
    
    # Check that image generation is disabled
    assert_equal false, provider.instance_variable_get(:@enable_image_generation)
  end

  # Test prompt generation
  test "generates basic prompt successfully" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    # This would need VCR cassettes for actual API calls
    VCR.use_cassette("ruby_llm_basic_generation") do
      config = {
        "service" => "RubyLLM",
        "openai_api_key" => ENV["OPENAI_API_KEY"] || "test-key",
        "model" => "gpt-4o-mini",
        "temperature" => 0.7
      }

      provider = ActiveAgent::GenerationProvider::RubyLLMProvider.new(config)
      
      # Create a simple prompt
      prompt = ActiveAgent::ActionPrompt::Prompt.new(
        action_name: "test_action",
        message: ActiveAgent::ActionPrompt::Message.new(
          content: "What is 2 + 2?",
          role: :user
        ),
        messages: [],
        instructions: nil,
        actions: [],
        options: {}
      )

      # Skip if we don't have real API keys
      if config["openai_api_key"] == "test-key"
        skip "Real API key required for integration test"
      end

      response = provider.generate(prompt)
      
      assert_not_nil response
      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_not_nil response.message
      assert_not_nil response.message.content
      assert_includes response.message.content.downcase, "4"
    end
  end

  # Test embedding generation
  test "generates embeddings successfully" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    VCR.use_cassette("ruby_llm_embedding_generation") do
      config = {
        "service" => "RubyLLM",
        "openai_api_key" => ENV["OPENAI_API_KEY"] || "test-key",
        "embedding_model" => "text-embedding-3-small"
      }

      provider = ActiveAgent::GenerationProvider::RubyLLMProvider.new(config)
      
      # Create an embedding prompt
      prompt = ActiveAgent::ActionPrompt::Prompt.new(
        action_name: "embed",
        message: ActiveAgent::ActionPrompt::Message.new(
          content: "Hello, world!",
          role: :user
        ),
        messages: [],
        instructions: nil,
        actions: [],
        options: { embedding_model: "text-embedding-3-small" }
      )

      # Skip if we don't have real API keys
      if config["openai_api_key"] == "test-key"
        skip "Real API key required for integration test"
      end

      response = provider.embed(prompt)
      
      assert_not_nil response
      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_not_nil response.message
      assert_not_nil response.message.content
      assert_instance_of Array, response.message.content
      assert response.message.content.all? { |val| val.is_a?(Numeric) }
    end
  end

  # Test provider switching
  test "uses specified provider over default" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    config = {
      "service" => "RubyLLM",
      "openai_api_key" => "openai-key",
      "anthropic_api_key" => "anthropic-key",
      "default_provider" => "openai"
    }

    provider = ActiveAgent::GenerationProvider::RubyLLMProvider.new(config)
    
    # Create a prompt with specific provider
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      action_name: "test",
      message: ActiveAgent::ActionPrompt::Message.new(
        content: "Test",
        role: :user
      ),
      messages: [],
      instructions: nil,
      actions: [],
      options: { provider: "anthropic" }
    )

    # Set the prompt before calling build_provider_parameters
    provider.instance_variable_set(:@prompt, prompt)
    params = provider.send(:build_provider_parameters)
    
    assert_equal :anthropic, params[:provider]
  end

  # Test structured output schema support
  test "includes schema in parameters when present" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    config = {
      "service" => "RubyLLM",
      "openai_api_key" => "test-key"
    }

    provider = ActiveAgent::GenerationProvider::RubyLLMProvider.new(config)
    
    schema = {
      type: "object",
      properties: {
        answer: { type: "string" },
        confidence: { type: "number" }
      },
      required: ["answer", "confidence"]
    }

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      action_name: "test",
      message: ActiveAgent::ActionPrompt::Message.new(
        content: "Test",
        role: :user
      ),
      messages: [],
      instructions: nil,
      actions: [],
      output_schema: schema,
      options: {}
    )

    provider.instance_variable_set(:@prompt, prompt)
    params = provider.send(:build_provider_parameters)
    
    assert_equal schema, params[:schema]
  end
end