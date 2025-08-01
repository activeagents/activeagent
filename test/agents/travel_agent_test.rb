require "test_helper"

class TravelAgentTest < ActiveSupport::TestCase
  test "travel agent search action with HTML format" do
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

  test "travel agent book action with text format" do
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

  test "travel agent confirm action with text format" do
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
