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
