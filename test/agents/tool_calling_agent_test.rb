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

      # Messages should include system messages first, then user, assistant, and tool messages
      assert response.prompt.messages.size >= 5
      
      # System messages should be first (multiple empty ones may be added during prompt flow)
      system_count = 0
      response.prompt.messages.each_with_index do |msg, i|
        break if msg.role != :system
        system_count = i + 1
      end
      assert system_count >= 1, "Should have at least one system message at the beginning"
      
      # After system messages, should have user message
      user_index = system_count
      assert_equal :user, response.prompt.messages[user_index].role
      assert_includes response.prompt.messages[user_index].content, "Calculate the area"
      
      # Then assistant message with tool call
      assistant_index = user_index + 1
      assert_equal :assistant, response.prompt.messages[assistant_index].role
      assert response.prompt.messages[assistant_index].action_requested
      
      # Then tool result
      tool_index = assistant_index + 1
      assert_equal :tool, response.prompt.messages[tool_index].role
      assert_equal "50.0", response.prompt.messages[tool_index].content
      
      # If there are more tool calls for doubling
      if response.prompt.messages.size > tool_index + 2
        assert_equal :assistant, response.prompt.messages[tool_index + 1].role
        assert_equal :tool, response.prompt.messages[tool_index + 2].role
        assert_equal "100.0", response.prompt.messages[tool_index + 2].content
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
      if tool_message
        assert_includes tool_message.content.downcase, "error"
      end
      assert_includes response.message.content.downcase, "divid"
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
      assert_includes response.message.content, "°F"
    end
  end
end
