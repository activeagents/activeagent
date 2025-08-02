require "test_helper"

class ActionsExamplesTest < ActiveSupport::TestCase
  test "using actions to prompt the agent with a templated message" do
    # region actions_prompt_agent_basic
    parameterized_agent = TravelAgent.with(message: "I want to find hotels in Paris")
    travel_prompt = parameterized_agent.search

    # The search action renders a view with the search results
    assert travel_prompt.message.content.include?("Travel Search Results")
    # endregion actions_prompt_agent_basic
  end

  test "agent uses actions with parameters" do
    # region actions_with_parameters
    # Pass parameters using the with method
    agent = TravelAgent.with(
      message: "Book this flight",
      flight_id: "AA456",
      passenger_name: "Alice Johnson"
    )

    # Access parameters in the action using params
    booking_prompt = agent.book
    assert booking_prompt.message.content.include?("AA456")
    assert booking_prompt.message.content.include?("Alice Johnson")
    # endregion actions_with_parameters
  end

  test "actions with different content types" do
    # region actions_content_types
    # HTML content for rich UI
    search_result = TravelAgent.with(
      departure: "NYC",
      destination: "London",
      results: [ { airline: "British Airways", price: 599, departure: "9:00 AM" } ]
    ).search
    assert search_result.message.content.include?("Travel Search Results")
    assert search_result.message.content.include?("British Airways")

    # Text content for simple responses
    confirm_result = TravelAgent.with(
      confirmation_number: "ABC123",
      passenger_name: "Test User"
    ).confirm
    assert confirm_result.message.content.include?("Your booking has been confirmed!")
    assert confirm_result.message.content.include?("ABC123")
    # endregion actions_content_types
  end

  test "using prompt_context for agent-driven generation" do
    # region actions_prompt_context_generation
    # Use prompt_context when you want the agent to determine actions
    agent = TravelAgent.with(message: "I need to book a flight to Paris")
    prompt_context = agent.prompt_context

    # The agent will have access to all available actions
    assert prompt_context.actions.is_a?(Array)
    assert prompt_context.actions.size > 0
    # Actions are available as function schemas

    # Generate a response (in real usage)
    # response = prompt_context.generate_now
    # endregion actions_prompt_context_generation
  end
end
