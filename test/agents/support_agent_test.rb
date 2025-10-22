# test/support_agent_test.rb
require "test_helper"

class SupportAgentTest < ActiveSupport::TestCase
  test "it renders a prompt with an 'Test' message using the Application Agent's prompt_context" do
    assert_equal "Test", SupportAgent.prompt(message: "Test").message.content
  end

  test "it renders a prompt_context generates a response with a tool call and performs the requested actions" do
    VCR.use_cassette("support_agent_prompt_context_tool_call_response") do
      # region support_agent_tool_call
      message = "Show me a cat"
      prompt = SupportAgent.prompt(message: message)
      # endregion support_agent_tool_call
      assert_equal message, prompt.message.content
      # region support_agent_tool_call_response
      response = prompt.generate_now
      # endregion support_agent_tool_call_response

      doc_example_output(response)

      # region messages_structure
      # Messages include system, user, assistant, and tool messages
      assert response.prompt.messages.size >= 5

      # Group messages by role
      system_messages = response.prompt.messages.select { |m| m.role == :system }
      user_messages = response.prompt.messages.select { |m| m.role == :user }
      assistant_messages = response.prompt.messages.select { |m| m.role == :assistant }
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }
      # endregion messages_structure

      # SupportAgent has instructions from generate_with
      assert system_messages.any?, "Should have system messages"
      assert_equal "You're a support agent. Your job is to help users with their questions.",
                   system_messages.first.content,
                   "System message should contain SupportAgent's generate_with instructions"

      assert_equal 1, user_messages.size
      assert_equal 2, assistant_messages.size
      assert_equal 1, tool_messages.size

      # region message_context
      # The response message is the last message in the context
      assert_equal response.message, response.prompt.messages.last
      # endregion message_context

      # region tool_messages
      # Tool messages contain the results of tool calls
      assert_includes tool_messages.first.content, "https://cataas.com/cat/"
      # endregion tool_messages

      # region messages_with_actions
      # Assistant messages with requested_actions indicate tool calls
      assistant_with_actions = assistant_messages.find { |m| m.requested_actions&.any? }
      assert assistant_with_actions, "Should have assistant message with requested actions"
      # endregion messages_with_actions
    end
  end

  test "it generates a sematic description for vector embeddings" do
    VCR.use_cassette("support_agent_tool_call") do
      message = "Show me a cat"
      prompt = SupportAgent.prompt(message: message)
      response = prompt.generate_now
      assert_equal message, SupportAgent.prompt(message: message).message.content

      # Messages include system, user, assistant, and tool messages
      assert response.prompt.messages.size >= 5

      # Group messages by role
      system_messages = response.prompt.messages.select { |m| m.role == :system }
      user_messages = response.prompt.messages.select { |m| m.role == :user }
      assistant_messages = response.prompt.messages.select { |m| m.role == :assistant }
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }

      # SupportAgent has instructions from generate_with
      assert system_messages.any?, "Should have system messages"
      assert_equal "You're a support agent. Your job is to help users with their questions.",
                   system_messages.first.content,
                   "System message should contain SupportAgent's generate_with instructions"

      assert_equal 1, user_messages.size
      assert_equal 2, assistant_messages.size
      assert_equal 1, tool_messages.size
    end
  end

  test "it makes a tool call with streaming enabled" do
    prompt = nil
    prompt_message = nil
    test_prompt_message = "Show me a cat"
    VCR.use_cassette("support_agent_streaming_tool_call") do
      prompt = SupportAgent.prompt(message: test_prompt_message)
      prompt_message = prompt.message.content
    end

    VCR.use_cassette("support_agent_streaming_tool_call_response") do
      response = prompt.generate_now
      assert_equal test_prompt_message, prompt_message

      # Messages include system, user, assistant, and tool messages
      assert response.prompt.messages.size >= 5

      # Group messages by role
      system_messages = response.prompt.messages.select { |m| m.role == :system }
      user_messages = response.prompt.messages.select { |m| m.role == :user }
      assistant_messages = response.prompt.messages.select { |m| m.role == :assistant }
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }

      # SupportAgent has instructions from generate_with
      assert system_messages.any?, "Should have system messages"
      assert_equal "You're a support agent. Your job is to help users with their questions.",
                   system_messages.first.content,
                   "System message should contain SupportAgent's generate_with instructions"

      assert_equal 1, user_messages.size
      assert_equal 2, assistant_messages.size
      assert_equal 1, tool_messages.size
    end
  end
end
