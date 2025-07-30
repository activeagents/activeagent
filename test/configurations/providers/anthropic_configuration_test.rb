require_relative "../base_configuration_test"

# Test for Anthropic Provider configuration handling
class AnthropicConfigurationTest < BaseConfigurationTest
  test "loads anthropic configuration from yml file" do
    test_config = <<~YAML
      test:
        anthropic:
          service: "Anthropic"
          access_token: "file-based-key"
          model: "claude-3-opus-20240229"
          temperature: 0.8
    YAML

    with_temp_config_file(test_config) do |config_path|
      reset_configuration!
      
      # Store and change Rails env
      original_env = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "test"

      ActiveAgent.load_configuration(config_path)

      config = ApplicationAgent.configuration(:anthropic)
      assert_equal "file-based-key", config.config["access_token"]
      assert_equal 0.8, config.config["temperature"]

      ENV["RAILS_ENV"] = original_env
    end
  end

  test "handles missing anthropic configuration gracefully" do
    # Save current config
    original_config = ActiveAgent.config.deep_dup
    reset_configuration!

    # Try to load non-existent file
    ActiveAgent.load_configuration("/path/to/nonexistent/file.yml")

    # Should not raise an error, config should be empty hash
    assert_equal ActiveAgent.config, {}

    # Restore original configuration
    reset_configuration!
    ActiveAgent.load_configuration(Rails.root.join("config/active_agent.yml"))
  end

  test "anthropic provider merges configuration options" do
    test_config = <<~YAML
      test:
        anthropic:
          service: "Anthropic"
          access_token: "default-key"
          model: "claude-3-opus-20240229"
          temperature: 0.7
    YAML

    with_temp_config_file(test_config) do |config_path|
      # Store and change Rails env
      original_env = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "test"

      reset_configuration!
      ActiveAgent.load_configuration(config_path)

      # Test merging additional options
      provider = ApplicationAgent.configuration(:anthropic, 
        temperature: 0.9, 
        max_tokens: 2000,
        custom_option: "anthropic-test"
      )

      # Original config values
      assert_equal "default-key", provider.config["access_token"]
      assert_equal "claude-3-opus-20240229", provider.config["model"]
      
      # Merged options (note: merged options use symbol keys)
      assert_equal 0.9, provider.config[:temperature]
      assert_equal 2000, provider.config[:max_tokens]
      assert_equal "anthropic-test", provider.config[:custom_option]

      ENV["RAILS_ENV"] = original_env
    end
  end

  test "anthropic configuration with environment variables" do
    test_config = <<~YAML
      test:
        anthropic:
          service: "Anthropic"
          access_token: <%= ENV['ANTHROPIC_TEST_KEY'] || 'default-test-key' %>
          model: <%= ENV['ANTHROPIC_MODEL'] || 'claude-3-opus-20240229' %>
    YAML

    with_temp_config_file(test_config) do |config_path|
      # Set test environment variables
      original_env = ENV["RAILS_ENV"]
      original_key = ENV['ANTHROPIC_TEST_KEY']
      original_model = ENV['ANTHROPIC_MODEL']
      
      ENV["RAILS_ENV"] = "test"
      ENV['ANTHROPIC_TEST_KEY'] = 'env-var-key'
      ENV['ANTHROPIC_MODEL'] = 'claude-3-haiku-20240307'

      reset_configuration!
      ActiveAgent.load_configuration(config_path)

      config = ApplicationAgent.configuration(:anthropic)
      assert_equal "env-var-key", config.config["access_token"]
      assert_equal "claude-3-haiku-20240307", config.config["model"]

      # Restore environment
      ENV["RAILS_ENV"] = original_env
      ENV['ANTHROPIC_TEST_KEY'] = original_key
      ENV['ANTHROPIC_MODEL'] = original_model
    end
  end
end