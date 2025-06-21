# test/support_agent_test.rb
require "test_helper"

class SupportAgentTest < ActiveSupport::TestCase
  test "it renders a prompt with an 'Test' message using the Application Agent's prompt_context" do
    assert_equal "Test", SupportAgent.with(message: "Test").prompt_context.message.content
  end

  test "it renders a prompt_context generates a response with a tool call and performs the requested actions" do
    VCR.use_cassette("support_agent_prompt_context_tool_call_response") do
      message = "Show me a cat"
      prompt = SupportAgent.with(message: message).prompt_context
      response = prompt.generate_now
      assert_equal message, SupportAgent.with(message: message).prompt_context.message.content
      assert_equal 4, response.prompt.messages.size
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal :assistant, response.prompt.messages[2].role
      assert_equal :tool, response.prompt.messages[3].role
    end
  end

  test "it generates a sematic description for vector embeddings" do
    VCR.use_cassette("support_agent_tool_call") do
      message = "Show me a cat"
      prompt = SupportAgent.with(message: message).prompt_context
      response = prompt.generate_now
      assert_equal message, SupportAgent.with(message: message).prompt_context.message.content
      assert_equal 4, response.prompt.messages.size
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal :assistant, response.prompt.messages[2].role
      assert_equal :tool, response.prompt.messages[3].role
    end
  end

  test "it makes a tool call with streaming enabled" do
    VCR.use_cassette("support_agent_streaming_tool_call") do
      message = "Show me a cat"
      prompt = SupportAgent.with(message: message).prompt_context
      response = prompt.generate_now
      assert_equal message, SupportAgent.with(message: message).prompt_context.message.content
      assert_equal 4, response.prompt.messages.size
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal :assistant, response.prompt.messages[2].role
      assert_equal :tool, response.prompt.messages[3].role
    end
  end
end
