require "test_helper"

class ToolCallingAgentTest < ActiveSupport::TestCase
  test "agent can make multiple tool calls in sequence until completion" do
    VCR.use_cassette("tool_calling_agent_multi_turn", record: :new_episodes) do
      # region multi_turn_tool_call
      message = "Calculate the area of a rectangle with width 5 and height 10, then double it"
      prompt = CalculatorAgent.with(message: message).prompt_context
      response = prompt.generate_now
      # endregion multi_turn_tool_call

      doc_example_output(response)
      
      # Should have system, user, assistant (tool call), tool result, assistant (final)
      assert response.prompt.messages.size >= 4
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal :assistant, response.prompt.messages[2].role
      assert response.prompt.messages[2].action_requested
      assert_equal :tool, response.prompt.messages[3].role
      
      # Check tool result
      assert_equal "50.0", response.prompt.messages[3].content
      
      # If there are more tool calls for doubling
      if response.prompt.messages.size > 5
        assert_equal :assistant, response.prompt.messages[4].role
        assert_equal :tool, response.prompt.messages[5].role
        assert_equal "100.0", response.prompt.messages[5].content
      end
    end
  end

  test "agent can render views from tool calls" do
    VCR.use_cassette("tool_calling_agent_view_render") do
      # region tool_call_with_view
      message = "Show me the current weather report"
      prompt = WeatherAgent.with(message: message).prompt_context
      response = prompt.generate_now
      # endregion tool_call_with_view

      doc_example_output(response)
      
      # Check that view was rendered as tool result
      tool_message = response.prompt.messages.find { |m| m.role == :tool }
      assert_not_nil tool_message
      assert_includes tool_message.content, "<div class=\"weather-report\">"
    end
  end

  test "agent handles tool errors gracefully and continues" do
    VCR.use_cassette("tool_calling_agent_error_handling") do
      # region tool_call_error_handling
      message = "Divide 10 by 0 and tell me what happens"
      prompt = CalculatorAgent.with(message: message).prompt_context
      response = prompt.generate_now
      # endregion tool_call_error_handling

      doc_example_output(response)
      
      # Should handle the error and provide a meaningful response
      tool_message = response.prompt.messages.find { |m| m.role == :tool }
      assert_includes tool_message.content.downcase, "error"
      assert_includes response.message.content.downcase, "divide"
    end
  end

  test "agent can chain multiple tools to solve complex tasks" do
    VCR.use_cassette("tool_calling_agent_chain") do
      # region tool_call_chain
      message = "Get the current temperature and convert it from Celsius to Fahrenheit"
      prompt = WeatherAgent.with(message: message).prompt_context
      response = prompt.generate_now
      # endregion tool_call_chain

      doc_example_output(response)
      
      # Should call get_temperature then convert_temperature
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }
      assert_equal 2, tool_messages.size
      assert_includes response.message.content, "Fahrenheit"
    end
  end
end