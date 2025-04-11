# test/support_agent_test.rb
require "test_helper"

class SupportAgentTest < ActiveSupport::TestCase
  test "it renders a prompt with an empty message using the Application Agent's text_prompt" do
    assert_equal "", SupportAgent.text_prompt.message.content
  end

  test "it renders a text_prompt generates a response with a tool call" do
    message = "Show me a cat"
    prompt = SupportAgent.with(message: message).text_prompt
    response = prompt.generate_now
    assert_equal message, SupportAgent.with(message: message).text_prompt.message.content
    assert_equal 4, response.prompt.messages.size
    assert_equal :system, response.prompt.messages[0].role
    assert_equal :user, response.prompt.messages[1].role
    assert_equal :assistant, response.prompt.messages[2].role
    assert_equal :tool, response.prompt.messages[3].role
  end
end
