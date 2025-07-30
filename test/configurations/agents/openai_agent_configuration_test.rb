require_relative "../base_configuration_test"

# Test for OpenAI Agent configuration handling
class OpenAIAgentConfigurationTest < BaseConfigurationTest
  def setup
    super
    
    # Configure OpenAI for this test class
    OpenAI.configure do |config|
      config.access_token = "test-api-key"
      config.organization_id = "test-organization-id"
      config.log_errors = Rails.env.development?
      config.request_timeout = 600
    end
  end

  class OpenAIClientAgent < ApplicationAgent
    layout "agent"
    generate_with :openai
  end

  test "loads configuration from environment" do
    # Save and reset configuration for this test
    original_config = ActiveAgent.config.deep_dup
    ActiveAgent.load_configuration("")
    
    # Since we're loading empty configuration, the provider should get no access token
    assert_nil OpenAIClientAgent.generation_provider.access_token
    
    # The OpenAI client will use the configuration we set in setup
    client = OpenAI::Client.new
    assert_equal "test-api-key", client.access_token
  end

  test "agent inherits provider configuration" do
    test_config = <<~YAML
      test:
        openai:
          service: "OpenAI"
          access_token: "agent-test-key"
          model: "gpt-4o-mini"
          temperature: 0.5
    YAML

    with_temp_config_file(test_config) do |config_path|
      original_env = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "test"

      reset_configuration!
      ActiveAgent.load_configuration(config_path)

      # Create a test agent class
      test_agent = Class.new(ApplicationAgent) do
        generate_with :openai
      end

      provider = test_agent.generation_provider
      assert_equal "agent-test-key", provider.config["access_token"]
      assert_equal "gpt-4o-mini", provider.config["model"]
      assert_equal 0.5, provider.config["temperature"]

      ENV["RAILS_ENV"] = original_env
    end
  end

  test "agent can override provider configuration" do
    test_config = <<~YAML
      test:
        openai:
          service: "OpenAI"
          access_token: "default-key"
          model: "gpt-4o-mini"
          temperature: 0.7
    YAML

    with_temp_config_file(test_config) do |config_path|
      original_env = ENV["RAILS_ENV"]
      ENV["RAILS_ENV"] = "test"

      reset_configuration!
      ActiveAgent.load_configuration(config_path)

      # Create a test agent class with overrides
      test_agent = Class.new(ApplicationAgent) do
        generate_with :openai, temperature: 0.9, model: "gpt-4"
      end

      # Check the base provider configuration
      provider = test_agent.generation_provider
      assert_equal "default-key", provider.config["access_token"]  # Not overridden
      
      # Check the agent's options which contain the overrides
      assert_equal 0.9, test_agent.options[:temperature]  # Overridden
      assert_equal "gpt-4", test_agent.options[:model]  # Overridden

      ENV["RAILS_ENV"] = original_env
    end
  end
end