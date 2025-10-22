# frozen_string_literal: true

require "test_helper"

module Providers
  class MockProviderTest < ActiveSupport::TestCase
    test "basic generation with mock provider" do
      # region mock_basic_example
      response = MockAgent.with(message: "What is ActiveAgent?").ask.generate_now
      # endregion mock_basic_example

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end

    # region mock_pig_latin_conversion
    test "converts input to pig latin" do
      response = MockAgent.with(message: "Hello world").ask.generate_now

      doc_example_output(response)

      assert response.success?
      # Mock provider converts to pig latin
      assert_includes response.message.content.downcase, "ello"
    end
    # endregion mock_pig_latin_conversion

    # region mock_response_structure
    test "returns proper response structure" do
      response = MockAgent.with(message: "Test message").ask.generate_now

      doc_example_output(response)

      assert_equal "assistant", response.message.role
      assert_not_nil response.raw_response
      assert_not_nil response.message.content
    end
    # endregion mock_response_structure

    # region mock_no_api_calls
    test "works offline without API calls" do
      # Mock provider doesn't make network requests
      response = MockAgent.with(message: "Offline test").ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
    # endregion mock_no_api_calls
  end
end
