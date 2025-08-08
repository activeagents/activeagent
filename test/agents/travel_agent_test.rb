require "test_helper"
require "ostruct"

class TravelAgentTest < ActiveAgentTestCase
  test "travel agent with instructions template" do
    # region travel_agent_instructions_template
    user = OpenStruct.new(name: "Alice Johnson")
    prompt = TravelAgent.with(user: user, message: "I need help planning my trip").prompt_context

    # The instructions template should be included in the prompt
    system_message = prompt.messages.find { |m| m.role == :system }
    assert_not_nil system_message
    assert_includes system_message.content, "Alice Johnson"
    assert_includes system_message.content, "`search` action to find hotels"
    assert_includes system_message.content, "`book` action to book a hotel"
    assert_includes system_message.content, "`confirm` action to confirm the booking"
    # endregion travel_agent_instructions_template
  end

  test "travel agent with custom user in instructions" do
    VCR.use_cassette("travel_agent_custom_user_instructions") do
      # region travel_agent_custom_user_instructions
      user = OpenStruct.new(name: "Bob Smith")
      message = "I need to find a hotel in Paris"
      prompt = TravelAgent.with(user: user, message: message).prompt_context
      system_message = prompt.messages.find { |m| m.role == :system }
      assert_includes system_message.content, "Bob Smith"
      
      response = prompt.generate_now
      
      # The instructions should have been personalized with the user's name
      system_message = response.prompt.messages.find { |m| m.role == :system }
      assert_includes system_message.content, "Bob Smith"

      # The agent should understand the task based on the instructions
      assert_not_nil response
      assert_not_nil response.message
      # endregion travel_agent_custom_user_instructions

      doc_example_output(response)
    end
  end

  test "travel agent search action with LLM interaction" do
    VCR.use_cassette("travel_agent_search_llm") do
      # region travel_agent_search_llm
      message = "Find flights from NYC to LAX"
      prompt = TravelAgent.with(message: message).prompt_context
      response = prompt.generate_now

      # The LLM should call the search tool and return results
      assert_not_nil response
      assert_not_nil response.message
      assert response.prompt.messages.size >= 2  # At least system and user messages
      # endregion travel_agent_search_llm

      doc_example_output(response)
    end
  end

  test "travel agent book action with LLM interaction" do
    VCR.use_cassette("travel_agent_book_llm") do
      # region travel_agent_book_llm
      message = "Book flight AA123 for John Doe"
      prompt = TravelAgent.with(message: message).prompt_context
      response = prompt.generate_now

      # The LLM should call the book tool
      assert_not_nil response
      assert_not_nil response.message
      assert response.prompt.messages.size >= 2
      # endregion travel_agent_book_llm

      doc_example_output(response, "travel_agent_book_llm")
    end
  end

  test "travel agent confirm action with LLM interaction" do
    VCR.use_cassette("travel_agent_confirm_llm") do
      # region travel_agent_confirm_llm
      message = "Confirm booking TRV789012 for Jane Smith"
      prompt = TravelAgent.with(message: message).prompt_context
      response = prompt.generate_now

      # The LLM should call the confirm tool
      assert_not_nil response
      assert_not_nil response.message
      assert response.prompt.messages.size >= 2
      # endregion travel_agent_confirm_llm

      doc_example_output(response)
    end
  end

  test "travel agent full conversation flow with LLM" do
    VCR.use_cassette("travel_agent_conversation_flow") do
      # region travel_agent_conversation_flow
      # Test a full conversation flow with the LLM
      message = "I need to search for flights from NYC to LAX, then book one and confirm it"
      prompt = TravelAgent.with(message: message).prompt_context
      response = prompt.generate_now

      # The LLM should understand the request and potentially call multiple tools
      assert_not_nil response
      assert_not_nil response.message
      assert response.prompt.messages.size >= 2  # At least system and user messages
      # endregion travel_agent_conversation_flow

      doc_example_output(response)
    end
  end

  # Keep the original tests to ensure the views still work correctly
  test "travel agent search view renders HTML format" do
    # region travel_agent_search_html
    response = TravelAgent.with(
      message: "Find flights from NYC to LAX",
      departure: "NYC",
      destination: "LAX",
      results: [
        { airline: "American Airlines", price: 299, departure: "10:00 AM" },
        { airline: "Delta", price: 350, departure: "2:00 PM" }
      ]
    ).search

    # The HTML view will be rendered with flight search results
    assert response.message.content.include?("Travel Search Results")
    assert response.message.content.include?("NYC")
    assert response.message.content.include?("LAX")
    # endregion travel_agent_search_html

    doc_example_output(response)
  end

  test "travel agent book view renders text format" do
    # region travel_agent_book_text
    response = TravelAgent.with(
      message: "Book flight AA123",
      flight_id: "AA123",
      passenger_name: "John Doe",
      confirmation_number: "CNF123456"
    ).book

    # The text view returns booking details
    assert response.message.content.include?("Booking flight AA123")
    assert response.message.content.include?("Passenger: John Doe")
    assert response.message.content.include?("Confirmation: CNF123456")
    assert response.message.content.include?("Status: Booking confirmed")
    # endregion travel_agent_book_text

    doc_example_output(response, "travel_agent_book_text")
  end

  test "travel agent confirm view renders text format" do
    # region travel_agent_confirm_text
    response = TravelAgent.with(
      message: "Confirm booking",
      confirmation_number: "TRV789012",
      passenger_name: "Jane Smith",
      flight_details: "AA123 - NYC to LAX, departing 10:00 AM"
    ).confirm

    # The text view returns a simple confirmation message
    assert response.message.content.include?("Your booking has been confirmed!")
    assert response.message.content.include?("TRV789012")
    assert response.message.content.include?("Jane Smith")
    # endregion travel_agent_confirm_text

    doc_example_output(response)
  end

  test "travel agent demonstrates multi-format support" do
    # region travel_agent_multi_format
    # Different actions use different formats based on their purpose
    search_response = TravelAgent.with(
      message: "Search flights",
      departure: "NYC",
      destination: "LAX",
      results: []
    ).search
    assert search_response.message.content.include?("Travel Search Results")  # Rich UI format

    book_response = TravelAgent.with(
      message: "Book flight",
      flight_id: "AA123",
      passenger_name: "Test User",
      confirmation_number: "CNF789"
    ).book
    assert book_response.message.content.include?("Booking flight AA123")   # Text format
    assert book_response.message.content.include?("Test User")

    confirm_response = TravelAgent.with(
      message: "Confirm",
      confirmation_number: "CNF789",
      passenger_name: "Test User"
    ).confirm
    assert confirm_response.message.content.include?("Your booking has been confirmed!") # Simple text format
    # endregion travel_agent_multi_format

    assert_not_nil search_response
    assert_not_nil book_response
    assert_not_nil confirm_response
  end
end
