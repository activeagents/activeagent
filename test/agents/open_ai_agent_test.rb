require "test_helper"

class OpenAIAgentTest < ActiveSupport::TestCase
  def setup
    # Configure OpenAI for this test class
    OpenAI.configure do |config|
      config.access_token = "test-api-key"
      config.organization_id = "test-organization-id"
      config.log_errors = Rails.env.development?
      config.request_timeout = 600
    end
  end

  test "it renders a prompt_context generates a response" do
    VCR.use_cassette("openai_prompt_context_response") do
      message = "Show me a cat"
      prompt = OpenAIAgent.with(message: message).prompt_context
      response = prompt.generate_now
      assert_equal message, OpenAIAgent.with(message: message).prompt_context.message.content
      assert_equal 3, response.prompt.messages.size
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal :assistant, response.prompt.messages[2].role
    end
  end
end

class OpenAIClientTest < ActiveSupport::TestCase
  def setup
    # Save and reset configuration for this test
    @original_config = ActiveAgent.config.deep_dup
    ActiveAgent.load_configuration("")
    
    # Configure OpenAI for this test class
    OpenAI.configure do |config|
      config.access_token = "test-api-key"
      config.organization_id = "test-organization-id"
      config.log_errors = Rails.env.development?
      config.request_timeout = 600
    end
  end

  def teardown
    # Restore original configuration
    ActiveAgent.instance_variable_set(:@config, nil)
    ActiveAgent.load_configuration(Rails.root.join("config/active_agent.yml"))
  end

  class OpenAIClientAgent < ApplicationAgent
    layout "agent"
    generate_with :openai
  end

  test "loads configuration from environment" do
    # Since we're loading empty configuration, the provider should get no access token
    assert_nil OpenAIClientAgent.generation_provider.access_token
    
    # The OpenAI client will use the configuration we set in setup
    client = OpenAI::Client.new
    assert_equal "test-api-key", client.access_token
  end
end
