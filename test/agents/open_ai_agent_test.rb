require "test_helper"

class OpenAIAgentTest < ActiveAgentTestCase
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

class OpenAIClientTest < ActiveAgentTestCase
  def setup
    super
    # Configure OpenAI before tests
    OpenAI.configure do |config|
      config.access_token = "test-api-key"
      config.organization_id = "test-organization-id"
      config.log_errors = Rails.env.development?
      config.request_timeout = 600
    end
  end

  test "loads configuration from environment" do
    # Use empty config to test environment-based configuration
    with_active_agent_config({}) do
      class OpenAIClientAgent < ApplicationAgent
        layout "agent"
        generate_with :openai
      end

      client = OpenAI::Client.new
      assert_equal OpenAIClientAgent.generation_provider.access_token, client.access_token
    end
  end
end
