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
      assert_equal 5, response.prompt.messages.size
      
      # System message
      assert_equal :system, response.prompt.messages[0].role
      assert_includes response.prompt.messages[0].content, "calculator"
      
      # User message
      assert_equal :user, response.prompt.messages[1].role
      assert_equal "Add 2 and 3", response.prompt.messages[1].content
      
      # Assistant makes tool call
      assert_equal :assistant, response.prompt.messages[2].role
      assert response.prompt.messages[2].action_requested
      assert_equal "add", response.prompt.messages[2].requested_actions.first.name
      
      # Tool response
      assert_equal :tool, response.prompt.messages[3].role
      assert_equal "5.0", response.prompt.messages[3].content
      
      # Assistant provides final answer
      assert_equal :assistant, response.prompt.messages[4].role
      assert_includes response.prompt.messages[4].content, "5"
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