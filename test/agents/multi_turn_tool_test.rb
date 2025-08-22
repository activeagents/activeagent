require "test_helper"

class MultiTurnToolTest < ActiveSupport::TestCase
  test "agent performs tool call and continues generation with result" do
    VCR.use_cassette("multi_turn_tool_basic") do
      # region multi_turn_basic
      message = "Add 2 and 3"
      prompt = CalculatorAgent.with(message: message).prompt_context
      response = prompt.generate_now
      # endregion multi_turn_basic

      doc_example_output(response)

      # Verify the conversation flow
      assert response.prompt.messages.size >= 5

      # Find messages by type
      system_messages = response.prompt.messages.select { |m| m.role == :system }
      user_messages = response.prompt.messages.select { |m| m.role == :user }
      assistant_messages = response.prompt.messages.select { |m| m.role == :assistant }
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }

      # Should have system messages
      assert system_messages.any?, "Should have system messages"

      # At least one system message should mention calculator if the agent has instructions
      if system_messages.any? { |m| m.content.present? }
        assert system_messages.any? { |m| m.content.include?("calculator") },
          "System message should mention calculator"
      end

      # User message
      assert_equal 1, user_messages.size
      assert_equal "Add 2 and 3", user_messages.first.content

      # Assistant makes tool call and provides final answer
      assert_equal 2, assistant_messages.size
      assert assistant_messages.first.action_requested
      assert_equal "add", assistant_messages.first.requested_actions.first.name

      # Tool response
      assert_equal 1, tool_messages.size
      assert_equal "5.0", tool_messages.first.content

      # Assistant provides final answer
      assert_includes assistant_messages.last.content, "5"
    end
  end

  test "agent chains multiple tool calls for complex task" do
    VCR.use_cassette("multi_turn_tool_chain") do
      # region multi_turn_chain
      message = "Calculate the area of a 5x10 rectangle, then multiply by 2"
      prompt = CalculatorAgent.with(message: message).prompt_context
      response = prompt.generate_now
      # endregion multi_turn_chain

      doc_example_output(response)

      # Should have at least 2 tool calls
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }
      assert tool_messages.size >= 2

      # First tool call calculates area (50)
      assert_equal "50.0", tool_messages[0].content

      # Second tool call multiplies by 2 (100)
      assert_equal "100.0", tool_messages[1].content

      # Final message should mention the result
      assert_includes response.message.content, "100"
    end
  end
end
