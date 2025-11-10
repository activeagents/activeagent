# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module Anthropic
    module CommonFormat
      class InstructionsTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class PreviewAgent < ActiveAgent::Base
          generate_with :anthropic, model: "claude-sonnet-4-5-20250929"

          def comprehensive_test
            prompt(
              instructions: "You are an expert travel assistant. Analyze destination images, use available tools to gather information, and provide comprehensive travel recommendations in JSON format.",

              messages: [
                { role: "assistant", text: "I'm ready to help you plan an amazing trip! What destination would you like to explore?" },
                { text: "I'm interested in this beautiful destination:" },
                { image: "https://framerusercontent.com/images/oEx786EYW2ZVL4Xf9hparOVLjHI.png?scale-down-to=64" },
                { text: "Please analyze this location and create a travel plan. Include weather info and suggest the best travel dates." }
              ],

              tools: [
                {
                  name: "get_weather_forecast",
                  description: "Get detailed weather forecast for a specific location and date range",
                  input_schema: {
                    type: "object",
                    properties: {
                      location: { type: "string", description: "City and country/state" },
                      start_date: { type: "string", description: "Start date (YYYY-MM-DD)" },
                      days: { type: "integer", description: "Number of days to forecast" }
                    },
                    required: [ "location" ]
                  }
                },
                {
                  name: "find_attractions",
                  description: "Find popular attractions and activities in a location",
                  input_schema: {
                    type: "object",
                    properties: {
                      location: { type: "string", description: "City and country/state" },
                      category: { type: "string", enum: [ "museums", "outdoor", "food", "entertainment", "all" ] }
                    },
                    required: [ "location" ]
                  }
                }
              ],

              temperature: 0.7,
              max_tokens: 2000,
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

          # Check messages content
          assert_includes preview, "I'm ready to help you plan an amazing trip"
          assert_includes preview, "I'm interested in this beautiful destination"
          assert_includes preview, "Please analyze this location and create a travel plan"

          # Check tools content
          assert_includes preview, "get_weather_forecast"
          assert_includes preview, "find_attractions"
          assert_includes preview, "Get detailed weather forecast"
          assert_includes preview, "Find popular attractions"

          # Check parameters in YAML section
          assert_includes preview, "temperature: 0.7"
          assert_includes preview, "max_tokens: 2000"
        end
      end
    end
  end
end
