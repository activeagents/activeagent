require_relative "../base_configuration_test"

# Test for OpenAI Provider configuration handling
class OpenAIConfigurationTest < BaseConfigurationTest
  test "loads openai configuration from yml file" do
    test_config = <<~YAML
      test:
        openai:
          service: "OpenAI"
          api_key: "file-based-key"
          model: "gpt-4o-mini"
          temperature: 0.8
    YAML

    with_temp_config_file(test_config) do |config_path|
      reset_configuration!
      
      # Store and change Rails env
      original_env = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "test"

      ActiveAgent.load_configuration(config_path)

      config = ApplicationAgent.configuration(:openai)
      assert_equal "file-based-key", config.config["api_key"]
      assert_equal 0.8, config.config["temperature"]

      ENV["RAILS_ENV"] = original_env
    end
  end

  test "handles missing openai configuration gracefully" do
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

  test "openai provider merges configuration options" do
    test_config = <<~YAML
      test:
        openai:
          service: "OpenAI"
          api_key: "default-key"
          model: "gpt-4o-mini"
          temperature: 0.7
    YAML

    with_temp_config_file(test_config) do |config_path|
      # Store and change Rails env
      original_env = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "test"

      reset_configuration!
      ActiveAgent.load_configuration(config_path)

      # Test merging additional options
      provider = ApplicationAgent.configuration(:openai, 
        temperature: 0.9, 
        max_tokens: 1000,
        custom_option: "test-value"
      )

      # Original config values
      assert_equal "default-key", provider.config["api_key"]
      assert_equal "gpt-4o-mini", provider.config["model"]
      
      # Merged options (note: merged options use symbol keys)
      assert_equal 0.9, provider.config[:temperature]
      assert_equal 1000, provider.config[:max_tokens]
      assert_equal "test-value", provider.config[:custom_option]

      ENV["RAILS_ENV"] = original_env
    end
  end

  test "openai configuration with environment variables" do
    test_config = <<~YAML
      test:
        openai:
          service: "OpenAI"
          api_key: <%= ENV['OPENAI_TEST_KEY'] || 'default-test-key' %>
          model: <%= ENV['OPENAI_MODEL'] || 'gpt-4o-mini' %>
    YAML

    with_temp_config_file(test_config) do |config_path|
      # Set test environment variables
      original_env = ENV["RAILS_ENV"]
      original_key = ENV['OPENAI_TEST_KEY']
      original_model = ENV['OPENAI_MODEL']
      
      ENV["RAILS_ENV"] = "test"
      ENV['OPENAI_TEST_KEY'] = 'env-var-key'
      ENV['OPENAI_MODEL'] = 'gpt-4'

      reset_configuration!
      ActiveAgent.load_configuration(config_path)

      config = ApplicationAgent.configuration(:openai)
      assert_equal "env-var-key", config.config["api_key"]
      assert_equal "gpt-4", config.config["model"]

      # Restore environment
      ENV["RAILS_ENV"] = original_env
      ENV['OPENAI_TEST_KEY'] = original_key
      ENV['OPENAI_MODEL'] = original_model
    end
  end
end