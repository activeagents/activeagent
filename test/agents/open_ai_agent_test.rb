require "test_helper"

class OpenAIAgentTest < ActiveSupport::TestCase
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

OpenAI.configure do |config|
  config.access_token = "test-api-key"
  config.organization_id = "test-organization-id"
  config.log_errors = Rails.env.development?
  config.request_timeout = 600
end

class OpenAIClientTest < ActiveSupport::TestCase
  real_config = ActiveAgent.config
  ActiveAgent.load_configuration("")
  class OpenAIClientAgent < ApplicationAgent
    layout "agent"
    generate_with :openai
  end

  test "loads configuration from environment" do
    client = OpenAI::Client.new
    assert_equal OpenAIClientAgent.generation_provider.access_token, client.access_token
    ActiveAgent.instance_variable_set(:@config, real_config)
  end
end
