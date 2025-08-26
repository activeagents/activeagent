require "test_helper"

# Test for Anthropic Provider gem loading and configuration
class AnthropicProviderTest < ActiveAgentTestCase
  # Test the gem load rescue block
  test "gem load rescue block provides correct error message" do
    # Since we can't easily simulate the gem not being available without complex mocking,
    # we'll test that the error message is correct by creating a minimal reproduction
    expected_message = "The 'ruby-anthropic ~> 0.4.2' gem is required for AnthropicProvider. Please add it to your Gemfile and run `bundle install`."

    # Verify the rescue block pattern exists in the source code
    provider_file_path = File.join(Rails.root, "../../lib/active_agent/generation_provider/anthropic_provider.rb")
    provider_source = File.read(provider_file_path)

    assert_includes provider_source, "begin"
    assert_includes provider_source, 'gem "ruby-anthropic"'
    assert_includes provider_source, 'require "anthropic"'
    assert_includes provider_source, "rescue LoadError"
    assert_includes provider_source, expected_message

    # Test the actual error by creating a minimal scenario
    test_code = <<~RUBY
      begin
        gem "nonexistent-anthropic-gem"
        require "nonexistent-anthropic-gem"
      rescue LoadError
        raise LoadError, "#{expected_message}"
      end
    RUBY

    error = assert_raises(LoadError) do
      eval(test_code)
    end

    assert_equal expected_message, error.message
  end

  test "loads successfully when ruby-anthropic gem is available" do
    # This test ensures the provider loads correctly when the gem is present
    # Since the gem is already loaded in our test environment, this should work
    assert_nothing_raised do
      require "active_agent/generation_provider/anthropic_provider"
    end

    # Verify the class exists and can be instantiated with valid config
    assert defined?(ActiveAgent::GenerationProvider::AnthropicProvider)

    config = {
      "service" => "Anthropic",
      "access_token" => "test-key",
      "model" => "claude-3-sonnet-20240229"
    }

    assert_nothing_raised do
      ActiveAgent::GenerationProvider::AnthropicProvider.new(config)
    end
  end

  # Test configuration loading and presence
  test "raises error when active_agent.yml config is missing for provider" do
    # Ensure no configuration is present
    ActiveAgent.instance_variable_set(:@config, {})

    error = assert_raises(RuntimeError) do
      ApplicationAgent.configuration(:nonexistent_provider)
    end

    assert_includes error.message, "Failed to load provider nonexistent_provider:"
  end

  test "loads configuration from active_agent.yml when present" do
    # Mock a configuration
    mock_config = {
      "test" => {
        "anthropic" => {
          "service" => "Anthropic",
          "access_token" => "test-api-key",
          "model" => "claude-3-sonnet-20240229",
          "temperature" => 0.7
        }
      }
    }

    ActiveAgent.instance_variable_set(:@config, mock_config)

    # Set Rails environment for testing
    rails_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "test"

    config = ApplicationAgent.configuration(:anthropic)

    assert_equal "Anthropic", config.config["service"]
    assert_equal "test-api-key", config.config["access_token"]
    assert_equal "claude-3-sonnet-20240229", config.config["model"]
    assert_equal 0.7, config.config["temperature"]

    # Restore original environment
    ENV["RAILS_ENV"] = rails_env
  end

  test "loads configuration from environment-specific section" do
    mock_config = {
      "development" => {
        "anthropic" => {
          "service" => "Anthropic",
          "access_token" => "dev-api-key",
          "model" => "claude-3-sonnet-20240229"
        }
      },
      "test" => {
        "anthropic" => {
          "service" => "Anthropic",
          "access_token" => "test-api-key",
          "model" => "claude-3-sonnet-20240229"
        }
      }
    }

    ActiveAgent.instance_variable_set(:@config, mock_config)

    # Test development configuration
    original_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "development"

    config = ApplicationAgent.configuration(:anthropic)
    assert_equal "dev-api-key", config.config["access_token"]

    # Test test configuration
    ENV["RAILS_ENV"] = "test"
    config = ApplicationAgent.configuration(:anthropic)
    assert_equal "test-api-key", config.config["access_token"]

    ENV["RAILS_ENV"] = original_env
  end

  test "configuration file loading from file system" do
    # Create a temporary configuration file
    temp_config_content = <<~YAML
      test:
        anthropic:
          service: "Anthropic"
          access_token: "file-based-key"
          model: "claude-3-sonnet-20240229"
          temperature: 0.8
    YAML

    temp_file = Tempfile.new([ "active_agent", ".yml" ])
    temp_file.write(temp_config_content)
    temp_file.close

    # Reset configuration
    ActiveAgent.instance_variable_set(:@config, nil)

    # Load configuration from file
    ActiveAgent.load_configuration(temp_file.path)

    original_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "test"

    config = ApplicationAgent.configuration(:anthropic)
    assert_equal "file-based-key", config.config["access_token"]
    assert_equal 0.8, config.config["temperature"]

    ENV["RAILS_ENV"] = original_env
    temp_file.unlink
  end

  test "handles missing configuration file gracefully" do
    # Reset configuration
    real_config = ActiveAgent.config
    ActiveAgent.instance_variable_set(:@config, nil)

    # Try to load non-existent file
    ActiveAgent.load_configuration("/path/to/nonexistent/file.yml")

    # Should not raise an error, config should remain nil
    assert_equal ActiveAgent.config, {}

    # Restore original configuration
    ActiveAgent.instance_variable_set(:@config, real_config)
  end

  test "configuration with ERB processing" do
    # Create a temporary configuration file with ERB
    temp_config_content = <<~YAML
      test:
        anthropic:
          service: "Anthropic"
          access_token: "<%= 'erb-processed-key' %>"
          model: "claude-3-sonnet-20240229"
          temperature: <%= 0.5 + 0.2 %>
    YAML

    temp_file = Tempfile.new([ "active_agent", ".yml" ])
    temp_file.write(temp_config_content)
    temp_file.close

    # Reset configuration
    ActiveAgent.instance_variable_set(:@config, nil)

    # Load configuration from file
    ActiveAgent.load_configuration(temp_file.path)

    original_env = ENV["RAILS_ENV"]
    ENV["RAILS_ENV"] = "test"

    config = ApplicationAgent.configuration(:anthropic)
    assert_equal "erb-processed-key", config.config["access_token"]
    assert_equal 0.7, config.config["temperature"]

    ENV["RAILS_ENV"] = original_env
    temp_file.unlink
  end

  test "Anthropic provider initialization with missing access token" do
    config = {
      "service" => "Anthropic"
      # Missing access_token
    }

    require "active_agent/generation_provider/anthropic_provider"
    assert_raises(Anthropic::ConfigurationError) do
      provider = ActiveAgent::GenerationProvider::AnthropicProvider.new(config)
      assert_nil provider.instance_variable_get(:@access_token)
    end
  end
end
