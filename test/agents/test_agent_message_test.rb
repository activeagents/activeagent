require "test_helper"

class TestAgentForMessages < ActiveAgent::Base
  generate_with :test, instructions: "You're a test agent."
end

class TestAgentMessageTest < ActiveSupport::TestCase
  test "it adds assistant message to context after generation" do
    message = "Test message"
    prompt = TestAgentForMessages.with(message: message).prompt_context
    
    # Before generation, should have system and user messages
    assert_equal 2, prompt.messages.size
    assert_equal :system, prompt.messages[0].role
    assert_equal :user, prompt.messages[1].role
    
    response = prompt.generate_now
    
    # After generation, should have system, user, and assistant messages
    assert_equal 3, response.prompt.messages.size
    assert_equal :system, response.prompt.messages[0].role
    assert_equal :user, response.prompt.messages[1].role
    assert_equal :assistant, response.prompt.messages[2].role
  end
end
