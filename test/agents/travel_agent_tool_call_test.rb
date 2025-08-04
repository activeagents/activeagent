require "test_helper"

class TravelAgentToolCallTest < ActiveAgentTestCase
  test "assistant tool call message contains flat params" do
    # Create a mock tool call action with flat params structure
    action = ActiveAgent::ActionPrompt::Action.new(
      id: "call_123",
      name: "search",
      params: { departure: "NYC", destination: "LAX" }
    )

    assert_equal "search", action.name
    assert_equal({ departure: "NYC", destination: "LAX" }, action.params)
  end

  test "travel agent search action receives params through perform_action" do
    # Create agent with context
    agent = TravelAgent.new
    agent.context = ActiveAgent::ActionPrompt::Prompt.new

    # Mock a tool call action
    action = ActiveAgent::ActionPrompt::Action.new(
      id: "call_search_123",
      name: "search",
      params: { departure: "NYC", destination: "LAX", results: [] }
    )

    # Call perform_action
    agent.send(:perform_action, action)

    # Verify the action can access params
    assert_equal "NYC", agent.instance_variable_get(:@departure)
    assert_equal "LAX", agent.instance_variable_get(:@destination)

    # Verify context was updated with tool message
    assert_equal :tool, agent.context.message.role
    assert_equal "call_search_123", agent.context.message.action_id
    assert_equal "search", agent.context.message.action_name
    assert agent.context.messages.last.role == :tool
  end

  test "travel agent book action receives params through perform_action" do
    # Create agent with context
    agent = TravelAgent.new
    agent.context = ActiveAgent::ActionPrompt::Prompt.new

    # Mock a tool call action
    action = ActiveAgent::ActionPrompt::Action.new(
      id: "call_book_456",
      name: "book",
      params: { flight_id: "AA123", passenger_name: "John Doe" }
    )

    # Call perform_action
    agent.send(:perform_action, action)

    # Verify the action can access params
    assert_equal "AA123", agent.instance_variable_get(:@flight_id)
    assert_equal "John Doe", agent.instance_variable_get(:@passenger_name)

    # Verify context was updated with tool message
    assert_equal :tool, agent.context.message.role
    assert_equal "call_book_456", agent.context.message.action_id
    assert_equal "book", agent.context.message.action_name
    assert agent.context.messages.last.role == :tool
  end

  test "travel agent confirm action receives params through perform_action" do
    # Create agent with context
    agent = TravelAgent.new
    agent.context = ActiveAgent::ActionPrompt::Prompt.new

    # Mock a tool call action
    action = ActiveAgent::ActionPrompt::Action.new(
      id: "call_confirm_789",
      name: "confirm",
      params: { confirmation_number: "CNF789", passenger_name: "Jane Smith" }
    )

    # Call perform_action
    agent.send(:perform_action, action)

    # Verify the action can access params
    assert_equal "CNF789", agent.instance_variable_get(:@confirmation_number)
    assert_equal "Jane Smith", agent.instance_variable_get(:@passenger_name)

    # Verify context was updated with tool message
    assert_equal :tool, agent.context.message.role
    assert_equal "call_confirm_789", agent.context.message.action_id
    assert_equal "confirm", agent.context.message.action_name
    assert agent.context.messages.last.role == :tool
  end

  test "perform_action sets params and updates context messages" do
    # Create agent
    agent = TravelAgent.new

    # Mock a tool call action with flat params
    action = ActiveAgent::ActionPrompt::Action.new(
      id: "call_456",
      name: "search",
      params: { departure: "NYC", destination: "LAX" }
    )

    # Create a context with initial messages
    agent.context = ActiveAgent::ActionPrompt::Prompt.new
    agent.context.messages = [
      ActiveAgent::ActionPrompt::Message.new(role: :system, content: "You are a travel agent"),
      ActiveAgent::ActionPrompt::Message.new(role: :user, content: "Find flights")
    ]
    initial_message_count = agent.context.messages.size

    # Call perform_action
    agent.send(:perform_action, action)

    # Verify params were set correctly from flat structure
    assert_equal({ departure: "NYC", destination: "LAX" }, agent.params)

    # Verify context was updated with tool message
    assert_equal initial_message_count + 1, agent.context.messages.size
    last_message = agent.context.messages.last
    assert_equal :tool, last_message.role
    assert_equal "call_456", last_message.action_id
    assert_equal "search", last_message.action_name
    assert_equal "call_456", last_message.generation_id
  end

  test "tool schema uses flat parameter structure" do
    agent = TravelAgent.new
    agent.context = ActiveAgent::ActionPrompt::Prompt.new

    # Load the search action schema
    schema = agent.send(:load_schema, "search", [ "travel_agent" ])

    # Verify the schema has flat structure
    assert_equal "function", schema["type"]
    assert_equal "search", schema["function"]["name"]
    assert_equal "object", schema["function"]["parameters"]["type"]
    assert schema["function"]["parameters"]["properties"].key?("departure")
    assert schema["function"]["parameters"]["properties"].key?("destination")
    assert_includes schema["function"]["parameters"]["required"], "destination"
  end
end
