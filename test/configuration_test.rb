require "test_helper"

# Test for Active Agent configuration loading and validation
class ActiveAgentConfigurationTest < ActiveSupport::TestCase
  def setup
    @original_config = ActiveAgent.config
    @original_rails_env = ENV["RAILS_ENV"]
  end

  def teardown
    ActiveAgent.instance_variable_set(:@config, @original_config) if @original_config
    ENV["RAILS_ENV"] = "test"
    ActiveAgent.load_configuration(Rails.root.join("config/active_agent.yml"))
  end

  test "loads configuration from active_agent.yml file" do
    ActiveAgent.instance_variable_set(:@config, nil)
    # Test loading from the actual dummy app configuration
    config_file = Rails.root.join("config/active_agent.yml")

    # Ensure the file exists
    assert File.exist?(config_file), "active_agent.yml should exist in test dummy app"

    # Reset and reload configuration
    ActiveAgent.instance_variable_set(:@config, nil)
    ActiveAgent.load_configuration(config_file)

    ENV["RAILS_ENV"] = "test"

    # Verify configuration was loaded
    assert_not_nil ActiveAgent.config
    assert ActiveAgent.config.key?("openai"), "Should have openai configuration"
    assert_equal "OpenAI", ActiveAgent.config["openai"]["service"]
  end

  test "handles missing configuration file gracefully" do
    ActiveAgent.instance_variable_set(:@config, nil)
    # Try to load non-existent file
    non_existent_file = "/tmp/nonexistent_active_agent.yml"

    assert_nothing_raised do
      ActiveAgent.load_configuration(non_existent_file)
    end

    # Configuration should remain nil when file doesn't exist
    assert_equal ActiveAgent.config, {}
    # Restore original configuration
  end

  test "processes ERB in configuration file" do
    ActiveAgent.instance_variable_set(:@config, nil)
    # Create a temporary config file with ERB
    erb_config = <<~YAML
      test:
        openai:
          service: "OpenAI"
          api_key: <%= "test-" + "key" %>
          model: "gpt-4o-mini"
          temperature: <%= 0.5 + 0.2 %>
          custom_setting: <%= Rails.env %>
    YAML

    temp_file = Tempfile.new([ "active_agent_erb", ".yml" ])
    temp_file.write(erb_config)
    temp_file.close

    ActiveAgent.instance_variable_set(:@config, nil)
    ActiveAgent.load_configuration(temp_file.path)

    ENV["RAILS_ENV"] = "test"
    config = ActiveAgent.config

    assert_equal "test-key", config["openai"]["api_key"]
    assert_equal 0.7, config["openai"]["temperature"]
    assert_equal "test", config["openai"]["custom_setting"]

    temp_file.unlink
  end

  test "selects environment-specific configuration" do
    ActiveAgent.instance_variable_set(:@config, nil)
    multi_env_config = <<~YAML
      development:
        openai:
          service: "OpenAI"
          api_key: "dev-key"
          model: "gpt-4o-mini"
      test:
        openai:
          service: "OpenAI"
          api_key: "test-key"
          model: "gpt-4o-mini"
      production:
        openai:
          service: "OpenAI"
          api_key: "prod-key"
          model: "gpt-4"
    YAML

    temp_file = Tempfile.new([ "active_agent_multi_env", ".yml" ])
    temp_file.write(multi_env_config)
    temp_file.close

    ActiveAgent.instance_variable_set(:@config, nil)
    ActiveAgent.load_configuration(temp_file.path)

    # Test development environment
    ENV["RAILS_ENV"] = "development"
    ActiveAgent.load_configuration(temp_file.path)
    assert_equal "dev-key", ActiveAgent.config["openai"]["api_key"]

    # Test test environment
    ENV["RAILS_ENV"] = "test"
    ActiveAgent.load_configuration(temp_file.path)
    assert_equal "test-key", ActiveAgent.config["openai"]["api_key"]

    # Test production environment
    ENV["RAILS_ENV"] = "production"
    ActiveAgent.load_configuration(temp_file.path)
    assert_equal "prod-key", ActiveAgent.config["openai"]["api_key"]
    assert_equal "gpt-4", ActiveAgent.config["openai"]["model"]

    temp_file.unlink
  end

  test "falls back to root configuration when environment not found" do
    ActiveAgent.instance_variable_set(:@config, nil)
    fallback_config = <<~YAML
      openai:
        service: "OpenAI"
        api_key: "fallback-key"
        model: "gpt-4o-mini"
      development:
        openai:
          service: "OpenAI"
          api_key: "dev-key"
          model: "gpt-4o-mini"
    YAML

    temp_file = Tempfile.new([ "active_agent_fallback", ".yml" ])
    temp_file.write(fallback_config)
    temp_file.close

    ActiveAgent.instance_variable_set(:@config, nil)

    # Test with environment that doesn't exist in config
    ENV["RAILS_ENV"] = "staging"
    ActiveAgent.load_configuration(temp_file.path)

    # Should fall back to root level configuration
    assert_equal "fallback-key", ActiveAgent.config["openai"]["api_key"]

    temp_file.unlink
    # Restore original configuration
  end

  test "provider configuration merges options" do
    base_config = {
      "test" => {
        "openai" => {
          "service" => "OpenAI",
          "api_key" => "test-key",
          "model" => "gpt-4o-mini"
        }
      }
    }

    ActiveAgent.instance_variable_set(:@config, base_config)
    ENV["RAILS_ENV"] = "test"

    # Test configuration with additional options
    provider = ApplicationAgent.configuration(:openai, temperature: 0.9, custom_option: "test")

    # Check the provider's config which should contain the merged configuration
    # Original config uses string keys, merged options use symbol keys
    assert_equal "test-key", provider.config["api_key"]
    assert_equal "gpt-4o-mini", provider.config["model"]
    assert_equal 0.9, provider.config[:temperature]  # Merged options use symbol keys
    assert_equal "test", provider.config[:custom_option]  # Merged options use symbol keys
  end

  test "configuration file structure matches expected format" do
    ActiveAgent.instance_variable_set(:@config, nil)
    # Verify the test dummy app's configuration file has the expected structure
    config_file = Rails.root.join("config/active_agent.yml")
    assert File.exist?(config_file)

    config_content = File.read(config_file)

    # Should have environment sections
    assert_includes config_content, "development:"
    assert_includes config_content, "test:"

    # Should have provider configurations
    assert_includes config_content, "openai:"
    assert_includes config_content, "service: \"OpenAI\""

    # Should have Rails credentials ERB
    assert_includes config_content, "<%= Rails.application.credentials"

    # Parse the YAML to ensure it's valid
    parsed_config = YAML.load(ERB.new(config_content).result, aliases: true)
    assert parsed_config.is_a?(Hash)
    assert parsed_config.key?("development")
    assert parsed_config.key?("test")
  end
end
