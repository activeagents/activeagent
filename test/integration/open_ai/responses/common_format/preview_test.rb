# frozen_string_literal: true

require_relative "../../../test_helper"

module Integration
  module OpenAI
    module Responses
      module CommonFormat
        class PreviewTest < ActiveSupport::TestCase
          include Integration::TestHelper

          class PreviewAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-4.1"

            def comprehensive_test
              prompt(
                instructions: "You are an expert travel assistant. Analyze destination images, use available tools to gather information, and provide comprehensive travel recommendations in JSON format.",
                input: "I'm interested in this beautiful destination (image: https://framerusercontent.com/images/oEx786EYW2ZVL4Xf9hparOVLjHI.png?scale-down-to=64). Please analyze this location and create a travel plan. Include weather info and suggest the best travel dates.",
                tools: [
                  {
                    type: "function",
                    name: "get_current_weather",
                    description: "Get the current weather in a given location",
                    parameters: {
                      type: "object",
                      properties: {
                        location: {
                          type: "string",
                          description: "The city and state, e.g. San Francisco, CA"
                        },
                        unit: {
                          type: "string",
                          enum: [ "celsius", "fahrenheit" ]
                        }
                      },
                      required: [ "location", "unit" ]
                    }
                  }
                ],

                temperature: 0.7,
                response_format: :json_object
              )
            end
          end

          test "Preview Building" do
            preview = PreviewAgent.comprehensive_test.prompt_preview

            assert_not_nil preview
            assert_kind_of String, preview

            # Check that it's markdown formatted
            assert_match(/^---/, preview)

            # Check instructions content
            assert_includes preview, "You are an expert travel assistant"
            assert_includes preview, "Analyze destination images"

            # Check input content
            assert_includes preview, "I'm interested in this beautiful destination"
            assert_includes preview, "Please analyze this location and create a travel plan"

            # Check tools content
            assert_includes preview, "get_current_weather"
            assert_includes preview, "Get the current weather in a given location"

            # Check parameters in YAML section
            assert_includes preview, "temperature: 0.7"
          end
        end
      end
    end
  end
end
