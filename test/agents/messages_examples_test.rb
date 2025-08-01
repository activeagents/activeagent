require "test_helper"
require "active_agent/action_prompt/message"
require "active_agent/action_prompt/action"

class MessagesExamplesTest < ActiveSupport::TestCase
  test "message structure and roles" do
    # region messages_structure
    # Create messages with different roles
    system_message = ActiveAgent::ActionPrompt::Message.new(
      role: :system,
      content: "You are a helpful travel agent."
    )

    user_message = ActiveAgent::ActionPrompt::Message.new(
      role: :user,
      content: "I need to book a flight to Tokyo"
    )

    assistant_message = ActiveAgent::ActionPrompt::Message.new(
      role: :assistant,
      content: "I'll help you find flights to Tokyo. Let me search for available options."
    )

    # Messages have roles and content
    assert_equal :system, system_message.role
    assert_equal :user, user_message.role
    assert_equal :assistant, assistant_message.role
    # endregion messages_structure
  end

  test "messages with requested actions" do
    # region messages_with_actions
    # Assistant messages can include requested actions
    message = ActiveAgent::ActionPrompt::Message.new(
      role: :assistant,
      content: "I'll search for flights to Paris for you.",
      requested_actions: [
        ActiveAgent::ActionPrompt::Action.new(
          name: "search",
          params: { destination: "Paris", departure_date: "2024-06-15" }
        )
      ]
    )

    assert message.action_requested
    assert_equal 1, message.requested_actions.size
    assert_equal "search", message.requested_actions.first.name
    # endregion messages_with_actions
  end

  test "tool messages for action responses" do
    # region tool_messages
    # Tool messages contain results from executed actions
    tool_message = ActiveAgent::ActionPrompt::Message.new(
      role: :tool,
      content: "Found 5 flights to London:\n- BA 247: $599\n- AA 106: $650\n- VS 003: $720",
      action_name: "search",
      action_id: "call_123abc"
    )

    assert_equal :tool, tool_message.role
    assert_equal "search", tool_message.action_name
    assert tool_message.content.include?("Found 5 flights")
    # endregion tool_messages
  end

  test "building message context for prompts" do
    # region message_context
    # Messages form the conversation context
    messages = [
      ActiveAgent::ActionPrompt::Message.new(
        role: :system,
        content: "You are a travel booking assistant."
      ),
      ActiveAgent::ActionPrompt::Message.new(
        role: :user,
        content: "Book me a flight to Rome"
      ),
      ActiveAgent::ActionPrompt::Message.new(
        role: :assistant,
        content: "I'll help you book a flight to Rome. When would you like to travel?"
      ),
      ActiveAgent::ActionPrompt::Message.new(
        role: :user,
        content: "Next Friday"
      )
    ]

    # Pass messages as context to agents
    agent = TravelAgent.with(
      message: "Find flights for next Friday",
      messages: messages
    )

    prompt = agent.prompt_context
    # The prompt will have the existing messages plus any added by the agent
    assert prompt.messages.size >= 5 # At least the messages we provided
    # endregion message_context
  end
end
