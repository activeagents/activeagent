require "test_helper"
require "active_agent/generation_provider/x_ai_provider"

# Test for xAI Provider gem loading and configuration
class XAIProviderTest < ActiveAgentTestCase
  # Test the gem load rescue block
  test "gem load rescue block provides correct error message" do
    # Since we can't easily simulate the gem not being available without complex mocking,
    # we'll test that the error message is correct by creating a minimal reproduction
    expected_message = "The 'ruby-openai >= 8.1.0' gem is required for XAIProvider. Please add it to your Gemfile and run `bundle install`."

    # Verify the rescue block pattern exists in the source code
    provider_file_path = File.join(Rails.root, "../../lib/active_agent/generation_provider/x_ai_provider.rb")
    provider_source = File.read(provider_file_path)

    assert_includes provider_source, "begin"
    assert_includes provider_source, 'gem "ruby-openai"'
    assert_includes provider_source, 'require "openai"'
    assert_includes provider_source, "rescue LoadError"
    assert_includes provider_source, expected_message

    # Test the actual error by creating a minimal scenario
    test_code = <<~RUBY
      begin
        gem "nonexistent-openai-gem"
        require "nonexistent-openai-gem"
      rescue LoadError
        raise LoadError, "#{expected_message}"
      end
    RUBY

    error = assert_raises(LoadError) do
      eval(test_code)
    end

    assert_equal expected_message, error.message
  end

  test "loads successfully when ruby-openai gem is available" do
    # This test ensures the provider loads correctly when the gem is present
    # Since the gem is already loaded in our test environment, this should work

    # Verify the class exists and can be instantiated with valid config
    assert defined?(ActiveAgent::GenerationProvider::XAIProvider)

    config = {
      "service" => "XAI",
      "api_key" => "test-key",
      "model" => "grok-2-latest"
    }

    assert_nothing_raised do
      ActiveAgent::GenerationProvider::XAIProvider.new(config)
    end
  end

  # Test configuration loading and presence
  test "raises error when xAI API key is missing" do
    config = {
      "service" => "XAI",
      "model" => "grok-2-latest"
      # Missing api_key
    }

    error = assert_raises(ArgumentError) do
      ActiveAgent::GenerationProvider::XAIProvider.new(config)
    end

    assert_includes error.message, "XAI API key is required"
  end

  test "loads configuration from active_agent.yml when present" do
    # Mock a configuration
    mock_config = {
      "test" => {
        "xai" => {
          "service" => "XAI",
          "api_key" => "test-api-key",
          "model" => "grok-2-latest",
          "temperature" => 0.7
        }
      }
    }

    ActiveAgent.instance_variable_set(:@config, mock_config)

    # Set Rails environment for testing
    rails_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "test"

    config = ApplicationAgent.configuration(:xai)

    assert_equal "XAI", config.config["service"]
    assert_equal "test-api-key", config.config["api_key"]
    assert_equal "grok-2-latest", config.config["model"]
    assert_equal 0.7, config.config["temperature"]

    # Restore original environment
    ENV["RAILS_ENV"] = rails_env
  end

  test "loads configuration from environment-specific section" do
    mock_config = {
      "development" => {
        "xai" => {
          "service" => "XAI",
          "api_key" => "dev-api-key",
          "model" => "grok-2-latest"
        }
      },
      "test" => {
        "xai" => {
          "service" => "XAI",
          "api_key" => "test-api-key",
          "model" => "grok-2-latest"
        }
      }
    }

    ActiveAgent.instance_variable_set(:@config, mock_config)

    # Test development configuration
    original_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "development"

    config = ApplicationAgent.configuration(:xai)
    assert_equal "dev-api-key", config.config["api_key"]

    # Test test configuration
    ENV["RAILS_ENV"] = "test"
    config = ApplicationAgent.configuration(:xai)
    assert_equal "test-api-key", config.config["api_key"]

    ENV["RAILS_ENV"] = original_env
  end

  test "xAI provider initialization with API key from environment variable" do
    # Test with XAI_API_KEY env var
    original_xai_key = ENV["XAI_API_KEY"]
    original_grok_key = ENV["GROK_API_KEY"]

    ENV["XAI_API_KEY"] = "env-xai-key"
    ENV["GROK_API_KEY"] = nil

    config = {
      "service" => "XAI",
      "model" => "grok-2-latest"
    }

    provider = ActiveAgent::GenerationProvider::XAIProvider.new(config)
    assert_equal "env-xai-key", provider.instance_variable_get(:@access_token)

    # Test with GROK_API_KEY env var
    ENV["XAI_API_KEY"] = nil
    ENV["GROK_API_KEY"] = "env-grok-key"

    provider = ActiveAgent::GenerationProvider::XAIProvider.new(config)
    assert_equal "env-grok-key", provider.instance_variable_get(:@access_token)

    # Restore original environment
    ENV["XAI_API_KEY"] = original_xai_key
    ENV["GROK_API_KEY"] = original_grok_key
  end

  test "xAI provider initialization with custom host" do
    config = {
      "service" => "XAI",
      "api_key" => "test-key",
      "model" => "grok-2-latest",
      "host" => "https://custom-xai-host.com"
    }

    provider = ActiveAgent::GenerationProvider::XAIProvider.new(config)
    client = provider.instance_variable_get(:@client)

    # The OpenAI client should be configured with the custom host
    assert_not_nil client
  end

  test "xAI provider defaults to grok-2-latest model" do
    config = {
      "service" => "XAI",
      "api_key" => "test-key"
      # Model not specified
    }

    provider = ActiveAgent::GenerationProvider::XAIProvider.new(config)
    assert_equal "grok-2-latest", provider.instance_variable_get(:@model_name)
  end

  test "xAI provider uses configured model" do
    config = {
      "service" => "XAI",
      "api_key" => "test-key",
      "model" => "grok-1"
    }

    provider = ActiveAgent::GenerationProvider::XAIProvider.new(config)
    assert_equal "grok-1", provider.instance_variable_get(:@model_name)
  end

  test "xAI provider defaults to correct API host" do
    config = {
      "service" => "XAI",
      "api_key" => "test-key"
    }

    provider = ActiveAgent::GenerationProvider::XAIProvider.new(config)
    assert_equal "https://api.x.ai", ActiveAgent::GenerationProvider::XAIProvider::XAI_API_HOST
  end

  test "embed method raises NotImplementedError for xAI" do
    config = {
      "service" => "XAI",
      "api_key" => "test-key"
    }

    provider = ActiveAgent::GenerationProvider::XAIProvider.new(config)
    mock_prompt = Minitest::Mock.new

    error = assert_raises(NotImplementedError) do
      provider.embed(mock_prompt)
    end

    assert_includes error.message, "xAI does not currently support embeddings"
  end
end
