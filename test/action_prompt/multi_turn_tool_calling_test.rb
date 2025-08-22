require "test_helper"
require "active_agent/action_prompt/base"
require "active_agent/action_prompt/prompt"
require "active_agent/action_prompt/message"
require "active_agent/action_prompt/action"

module ActiveAgent
  module ActionPrompt
    class MultiTurnToolCallingTest < ActiveSupport::TestCase
      class TestToolAgent < ActiveAgent::ActionPrompt::Base
        attr_accessor :tool_results

        def initialize
          super
          @tool_results = {}
        end

        def search_web
          @tool_results[:search_web] = "Found 10 results for #{params[:query]}"
          # Call prompt with a message body to generate the tool response
          prompt(message: @tool_results[:search_web])
        end

        def get_weather
          @tool_results[:get_weather] = "Weather in #{params[:location]}: Sunny, 72°F"
          # Call prompt with a message body to generate the tool response
          prompt(message: @tool_results[:get_weather])
        end

        def calculate
          result = eval(params[:expression])
          @tool_results[:calculate] = "Result: #{result}"
          # Call prompt with a message body to generate the tool response
          prompt(message: @tool_results[:calculate])
        end
      end

      setup do
        @agent = TestToolAgent.new
        @agent.context.messages << Message.new(role: :system, content: "You are a helpful assistant.")
        @agent.context.messages << Message.new(role: :user, content: "What's the weather in NYC and search for restaurants there?")
      end

      test "assistant message with tool_calls is preserved when performing actions" do
        # Create a mock response with tool calls
        assistant_message = Message.new(
          role: :assistant,
          content: "I'll help you with that. Let me check the weather and search for restaurants in NYC.",
          action_requested: true,
          raw_actions: [
            {
              "id" => "call_001",
              "type" => "function",
              "function" => {
                "name" => "get_weather",
                "arguments" => '{"location": "NYC"}'
              }
            }
          ],
          requested_actions: [
            Action.new(
              id: "call_001",
              name: "get_weather",
              params: { location: "NYC" }
            )
          ]
        )

        # Add assistant message to context (simulating what update_context does)
        @agent.context.messages << assistant_message

        # Perform the action
        @agent.send(:perform_action, assistant_message.requested_actions.first)

        # Verify the assistant message is still there
        assistant_messages = @agent.context.messages.select { |m| m.role == :assistant }
        assert_equal 1, assistant_messages.count
        assert_equal assistant_message, assistant_messages.first
        assert assistant_messages.first.raw_actions.present?

        # Verify the tool response was added
        tool_messages = @agent.context.messages.select { |m| m.role == :tool }
        assert_equal 1, tool_messages.count
        assert_equal "call_001", tool_messages.first.action_id
        assert_equal "get_weather", tool_messages.first.action_name
      end

      test "tool response messages have correct action_id matching tool_call id" do
        action = Action.new(
          id: "call_abc123",
          name: "search_web",
          params: { query: "NYC restaurants" }
        )

        # Add an assistant message with tool_calls
        @agent.context.messages << Message.new(
          role: :assistant,
          content: "Searching for restaurants",
          raw_actions: [ {
            "id" => "call_abc123",
            "type" => "function",
            "function" => {
              "name" => "search_web",
              "arguments" => '{"query": "NYC restaurants"}'
            }
          } ]
        )

        @agent.send(:perform_action, action)

        tool_message = @agent.context.messages.last
        assert_equal :tool, tool_message.role
        assert_equal "call_abc123", tool_message.action_id
        assert_equal action.id, tool_message.action_id
      end

      test "multiple tool calls result in correct message sequence" do
        # First tool call
        first_assistant = Message.new(
          role: :assistant,
          content: "Getting weather first",
          action_requested: true,
          raw_actions: [ {
            "id" => "call_001",
            "type" => "function",
            "function" => { "name" => "get_weather", "arguments" => '{"location": "NYC"}' }
          } ],
          requested_actions: [
            Action.new(id: "call_001", name: "get_weather", params: { location: "NYC" })
          ]
        )

        @agent.context.messages << first_assistant
        @agent.send(:perform_action, first_assistant.requested_actions.first)

        # Second tool call
        second_assistant = Message.new(
          role: :assistant,
          content: "Now searching for restaurants",
          action_requested: true,
          raw_actions: [ {
            "id" => "call_002",
            "type" => "function",
            "function" => { "name" => "search_web", "arguments" => '{"query": "NYC restaurants"}' }
          } ],
          requested_actions: [
            Action.new(id: "call_002", name: "search_web", params: { query: "NYC restaurants" })
          ]
        )

        @agent.context.messages << second_assistant
        @agent.send(:perform_action, second_assistant.requested_actions.first)

        # Verify message sequence
        messages = @agent.context.messages

        # Filter to get the main messages (system, user, assistants, tools)
        system_messages = messages.select { |m| m.role == :system }
        user_messages = messages.select { |m| m.role == :user }
        assistant_messages = messages.select { |m| m.role == :assistant }
        tool_messages = messages.select { |m| m.role == :tool }

        # Agent starts with empty system message, plus the one we added in setup
        assert_equal 2, system_messages.count
        assert_equal 1, user_messages.count
        assert_equal 2, assistant_messages.count
        assert_equal 2, tool_messages.count

        # Verify tool response IDs match
        assert_equal "call_001", tool_messages[0].action_id
        assert_equal "call_002", tool_messages[1].action_id
      end

      test "perform_actions handles multiple actions from single response" do
        actions = [
          Action.new(id: "call_001", name: "get_weather", params: { location: "NYC" }),
          Action.new(id: "call_002", name: "search_web", params: { query: "NYC restaurants" })
        ]

        assistant_message = Message.new(
          role: :assistant,
          content: "Getting both pieces of information",
          raw_actions: [
            { "id" => "call_001", "type" => "function", "function" => { "name" => "get_weather" } },
            { "id" => "call_002", "type" => "function", "function" => { "name" => "search_web" } }
          ]
        )

        @agent.context.messages << assistant_message
        @agent.send(:perform_actions, requested_actions: actions)

        tool_messages = @agent.context.messages.select { |m| m.role == :tool }
        assert_equal 2, tool_messages.count
        assert_equal [ "call_001", "call_002" ], tool_messages.map(&:action_id)
        assert_equal [ "get_weather", "search_web" ], tool_messages.map(&:action_name)
      end

      test "handle_response preserves message flow for tool calls" do
        # Create a mock response with tool calls
        mock_response = Struct.new(:message, :prompt).new
        mock_response.message = Message.new(
          role: :assistant,
          content: "I'll calculate that for you",
          action_requested: true,
          requested_actions: [
            Action.new(id: "calc_001", name: "calculate", params: { expression: "2 + 2" })
          ],
          raw_actions: [ {
            "id" => "calc_001",
            "type" => "function",
            "function" => { "name" => "calculate", "arguments" => '{"expression": "2 + 2"}' }
          } ]
        )

        # Mock the generation provider
        mock_provider = Minitest::Mock.new
        mock_provider.expect(:generate, nil, [ @agent.context ])
        mock_provider.expect(:response, mock_response)

        @agent.instance_variable_set(:@generation_provider, mock_provider)

        # Simulate update_context adding the assistant message
        @agent.context.messages << mock_response.message

        # Count messages before handle_response
        initial_message_count = @agent.context.messages.count

        # Call handle_response (without continue_generation to avoid needing full provider setup)
        @agent.stub(:continue_generation, mock_response) do
          result = @agent.send(:handle_response, mock_response)

          # Should have added tool message(s) for the action
          # Note: with the fix, the action's prompt call now properly renders and adds messages
          assert @agent.context.messages.count > initial_message_count

          # Last message should be the tool response
          last_message = @agent.context.messages.last
          assert_equal :tool, last_message.role
          assert_equal "calc_001", last_message.action_id
        end
      end

      test "tool message does not overwrite assistant message" do
        assistant_message = Message.new(
          role: :assistant,
          content: "Original assistant message",
          action_requested: true,
          requested_actions: [
            Action.new(id: "test_001", name: "search_web", params: { query: "test" })
          ]
        )

        # Store reference to original assistant message
        @agent.context.messages << assistant_message
        original_assistant = @agent.context.messages.last

        # Perform action
        @agent.send(:perform_action, assistant_message.requested_actions.first)

        # Find the assistant message again
        assistant_in_context = @agent.context.messages.find { |m| m.role == :assistant }

        # Verify it's still the same message with same content
        assert_equal original_assistant.object_id, assistant_in_context.object_id
        assert_equal "Original assistant message", assistant_in_context.content
        assert_equal :assistant, assistant_in_context.role
      end

      test "context cloning in perform_action preserves messages" do
        # Add initial messages
        initial_messages = @agent.context.messages.dup

        action = Action.new(
          id: "test_clone",
          name: "search_web",
          params: { query: "cloning test" }
        )

        @agent.send(:perform_action, action)

        # After perform_action, we expect:
        # - Original system message preserved
        # - Original user message preserved
        # - New tool message added

        system_messages = @agent.context.messages.select { |m| m.role == :system }
        user_messages = @agent.context.messages.select { |m| m.role == :user }
        tool_messages = @agent.context.messages.select { |m| m.role == :tool }

        # The system messages may be modified during prompt flow
        # What matters is we have system messages and the user message is preserved
        assert system_messages.any?, "Should have system messages"
        assert_equal 1, user_messages.count, "Should have one user message"
        assert_equal "What's the weather in NYC and search for restaurants there?", user_messages.first.content
        assert_equal 1, tool_messages.count, "Should have one tool message"
        assert_equal "Found 10 results for cloning test", tool_messages.first.content
      end
    end
  end
end
