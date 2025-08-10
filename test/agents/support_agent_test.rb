# test/support_agent_test.rb
require "test_helper"

class SupportAgentTest < ActiveSupport::TestCase
  test "it renders a prompt with an 'Test' message using the Application Agent's prompt_context" do
    assert_equal "Test", SupportAgent.with(message: "Test").prompt_context.message.content
  end

  test "it renders a prompt_context generates a response with a tool call and performs the requested actions" do
    VCR.use_cassette("support_agent_prompt_context_tool_call_response") do
      # region support_agent_tool_call
      message = "Show me a cat"
      prompt = SupportAgent.with(message: message).prompt_context
      # endregion support_agent_tool_call
      assert_equal message, prompt.message.content
      # region support_agent_tool_call_response
      response = prompt.generate_now
      # endregion support_agent_tool_call_response

      doc_example_output(response)
      assert_equal 5, response.prompt.messages.size
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal :assistant, response.prompt.messages[2].role
      assert_equal :tool, response.prompt.messages[3].role
      assert_equal :assistant, response.prompt.messages[4].role
      assert_equal response.message, response.prompt.messages.last
      assert_includes response.prompt.messages[3].content, "https://cataas.com/cat/"
    end
  end

  test "it generates a sematic description for vector embeddings" do
    VCR.use_cassette("support_agent_tool_call") do
      message = "Show me a cat"
      prompt = SupportAgent.with(message: message).prompt_context
      response = prompt.generate_now
      assert_equal message, SupportAgent.with(message: message).prompt_context.message.content
      assert_equal 5, response.prompt.messages.size
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal :assistant, response.prompt.messages[2].role
      assert_equal :tool, response.prompt.messages[3].role
      assert_equal :assistant, response.prompt.messages[4].role
    end
  end

  test "it makes a tool call with streaming enabled" do
    prompt = nil
    prompt_message = nil
    test_prompt_message = "Show me a cat"
    VCR.use_cassette("support_agent_streaming_tool_call") do
      prompt = SupportAgent.with(message: test_prompt_message).prompt_context
      prompt_message = prompt.message.content
    end

    VCR.use_cassette("support_agent_streaming_tool_call_response") do
      response = prompt.generate_now
      assert_equal test_prompt_message, prompt_message
      assert_equal 5, response.prompt.messages.size
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal :assistant, response.prompt.messages[2].role
      assert_equal :tool, response.prompt.messages[3].role
      assert_equal :assistant, response.prompt.messages[4].role
    end
  end
end
