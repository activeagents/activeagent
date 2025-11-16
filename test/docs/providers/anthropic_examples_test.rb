# frozen_string_literal: true

require "test_helper"

module Providers
  class AnthropicProviderTest < ActiveSupport::TestCase
    test "basic generation with Anthropic Claude" do
      VCR.use_cassette("docs/providers/anthropic/basic_generation") do
        # region anthropic_basic_example
        response = AnthropicAgent.with(
          message: "What is the Model Context Protocol?"
        ).ask.generate_now
        # endregion anthropic_basic_example

        doc_example_output(response)

        assert response.success?
        assert_not_nil response.message.content
        assert response.message.content.length > 0
      end
    end

    class ResponseFormatTest < ActiveSupport::TestCase
      # region response_format_json_object_agent
      class DataExtractionAgent < ApplicationAgent
        generate_with :anthropic, model: "claude-haiku-4-5"

        def extract_colors
          prompt(
            "Return a JSON object with three primary colors in an array named 'colors'.",
            response_format: { type: "json_object" }
          )
        end
      end
      # endregion response_format_json_object_agent

      test "response format json_object" do
        VCR.use_cassette("docs/providers/anthropic/response_format/json_object") do
          # region response_format_json_object_example
          response = DataExtractionAgent.extract_colors.generate_now
          colors = response.message.parsed_json # Parsed JSON hash
          # => { colors: ["red", "blue", "yellow"] }
          # endregion response_format_json_object_example

          assert_equal({ colors: [ "red", "blue", "yellow" ] }, colors)
        end
      end
    end
  end
end
