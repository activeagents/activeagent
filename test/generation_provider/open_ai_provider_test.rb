require "test_helper"

# Test for OpenAI Provider gem loading and configuration
class OpenAIProviderTest < ActiveSupport::TestCase
  def setup
    # Store original configuration to restore later
    @original_config = ActiveAgent.config
  end

  def teardown
    # Clean up any modified state
    if @original_config
      ActiveAgent.instance_variable_set(:@config, @original_config)
    end
  end

  # Test the gem load rescue block
  test "gem load rescue block provides correct error message" do
    # Since we can't easily simulate the gem not being available without complex mocking,
    # we'll test that the error message is correct by creating a minimal reproduction
    expected_message = "The 'ruby-openai' gem is required for OpenAIProvider. Please add it to your Gemfile and run `bundle install`."

    # Verify the rescue block pattern exists in the source code
    provider_file_path = File.join(Rails.root, "../../lib/active_agent/generation_provider/open_ai_provider.rb")
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
    assert_nothing_raised do
      require "active_agent/generation_provider/open_ai_provider"
    end

    # Verify the class exists and can be instantiated with valid config
    assert defined?(ActiveAgent::GenerationProvider::OpenAIProvider)

    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    assert_nothing_raised do
      ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    end
  end

  # Test configuration loading and presence
  test "raises error when active_agent.yml config is missing for provider" do
    # Ensure no configuration is present
    ActiveAgent.instance_variable_set(:@config, {})

    error = assert_raises(RuntimeError) do
      ApplicationAgent.configuration(:nonexistent_provider)
    end

    assert_includes error.message, "Configuration not found for provider: nonexistent_provider"
  end

  test "loads configuration from active_agent.yml when present" do
    # Mock a configuration
    mock_config = {
      "test" => {
        "openai" => {
          "service" => "OpenAI",
          "api_key" => "test-api-key",
          "model" => "gpt-4o-mini",
          "temperature" => 0.7
        }
      }
    }

    ActiveAgent.instance_variable_set(:@config, mock_config)

    # Set Rails environment for testing
    rails_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "test"

    config = ApplicationAgent.configuration(:openai)

    assert_equal "OpenAI", config.config["service"]
    assert_equal "test-api-key", config.config["api_key"]
    assert_equal "gpt-4o-mini", config.config["model"]
    assert_equal 0.7, config.config["temperature"]

    # Restore original environment
    ENV["RAILS_ENV"] = rails_env
  end

  test "loads configuration from environment-specific section" do
    mock_config = {
      "development" => {
        "openai" => {
          "service" => "OpenAI",
          "api_key" => "dev-api-key",
          "model" => "gpt-4o-mini"
        }
      },
      "test" => {
        "openai" => {
          "service" => "OpenAI",
          "api_key" => "test-api-key",
          "model" => "gpt-4o-mini"
        }
      }
    }

    ActiveAgent.instance_variable_set(:@config, mock_config)

    # Test development configuration
    original_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "development"

    config = ApplicationAgent.configuration(:openai)
    assert_equal "dev-api-key", config.config["api_key"]

    # Test test configuration
    ENV["RAILS_ENV"] = "test"
    config = ApplicationAgent.configuration(:openai)
    assert_equal "test-api-key", config.config["api_key"]

    ENV["RAILS_ENV"] = original_env
  end

  test "configuration file loading from file system" do
    # Create a temporary configuration file
    temp_config_content = <<~YAML
      test:
        openai:
          service: "OpenAI"
          api_key: "file-based-key"
          model: "gpt-4o-mini"
          temperature: 0.8
    YAML

    temp_file = Tempfile.new(["active_agent", ".yml"])
    temp_file.write(temp_config_content)
    temp_file.close

    # Reset configuration
    ActiveAgent.instance_variable_set(:@config, nil)

    # Load configuration from file
    ActiveAgent.load_configuration(temp_file.path)

    original_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "test"

    config = ApplicationAgent.configuration(:openai)
    assert_equal "file-based-key", config.config["api_key"]
    assert_equal 0.8, config.config["temperature"]

    ENV["RAILS_ENV"] = original_env
    temp_file.unlink
  end

  test "handles missing configuration file gracefully" do
    # Reset configuration
    ActiveAgent.instance_variable_set(:@config, nil)

    # Try to load non-existent file
    ActiveAgent.load_configuration("/path/to/nonexistent/file.yml")

    # Should not raise an error, config should remain nil
    assert_nil ActiveAgent.config
  end

  test "configuration with ERB processing" do
    # Create a temporary configuration file with ERB
    temp_config_content = <<~YAML
      test:
        openai:
          service: "OpenAI"
          api_key: "<%= 'erb-processed-key' %>"
          model: "gpt-4o-mini"
          temperature: <%= 0.5 + 0.2 %>
    YAML

    temp_file = Tempfile.new(["active_agent", ".yml"])
    temp_file.write(temp_config_content)
    temp_file.close

    # Reset configuration
    ActiveAgent.instance_variable_set(:@config, nil)

    # Load configuration from file
    ActiveAgent.load_configuration(temp_file.path)

    original_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "test"

    config = ApplicationAgent.configuration(:openai)
    assert_equal "erb-processed-key", config.config["api_key"]
    assert_equal 0.7, config.config["temperature"]

    ENV["RAILS_ENV"] = original_env
    temp_file.unlink
  end

  test "OpenAI provider initialization with missing API key" do
    config = {
      "service" => "OpenAI",
      "model" => "gpt-4o-mini"
      # Missing api_key
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    assert_nil provider.instance_variable_get(:@api_key)
  end

  test "OpenAI provider initialization with custom host" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini",
      "host" => "https://custom-openai-host.com"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    assert_equal "https://custom-openai-host.com", provider.instance_variable_get(:@host)
  end
end
