# frozen_string_literal: true

require_relative "../test_helper"

module Integration
  module Mock
    module CommonFormat
      class PreviewTest < ActiveSupport::TestCase
        include Integration::Mock::TestHelper

        class PreviewAgent < ActiveAgent::Base
          generate_with :mock

          def comprehensive_test
            prompt(
              instructions: "You are an expert travel assistant. Analyze destination images, use available tools to gather information, and provide comprehensive travel recommendations in JSON format.",

              messages: [
                { text: "Please analyze this location and create a travel plan. Include weather info and suggest the best travel dates." }
              ],

              temperature: 0.7,
              max_tokens: 2000,
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
          assert_includes preview, "Please analyze this location and create a travel plan"

          # Check parameters in YAML section
          assert_includes preview, "temperature: 0.7"
          assert_includes preview, "max_tokens: 2000"
        end
      end
    end
  end
end
