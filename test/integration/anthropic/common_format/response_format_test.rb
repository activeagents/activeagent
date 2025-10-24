# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module Anthropic
    module CommonFormat
      class ResponseFormatTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          generate_with :anthropic, model: "claude-haiku-4-5", max_tokens: 1024

          RESPONSE_TEXT = {
            model: "claude-haiku-4-5",
            messages: [
              {
                role: "user",
                content: "List three primary colors."
              }
            ],
            max_tokens: 1024
          }
          def response_text
            prompt(
              "List three primary colors.",
              response_format: { type: "text" }
            )
          end

          RESPONSE_JSON_OBJECT = {
            model: "claude-haiku-4-5",
            messages: [
              {
                role: "user",
                content: "Return a JSON object with three primary colors in an array named 'colors'."
              },
              {
                role: "assistant",
                content: "Here is the JSON requested:\n{"
              }
            ],
            max_tokens: 1024
          }
          def response_json_object
            prompt(
              "Return a JSON object with three primary colors in an array named 'colors'.",
              response_format: { type: "json_object" }
            )
          end
        end

        ################################################################################
        # This automatically runs all the tests for these the test actions
        ################################################################################
        [
          :response_text,
          :response_json_object
        ].each do |action_name|
          test_request_builder(TestAgent, action_name, :generate_now, TestAgent.const_get(action_name.to_s.upcase, true))
        end

        test "response format: text" do
          agent_name    = TestAgent.name.demodulize.underscore
          action_name   = "response_text"
          cassette_name = [ self.class.name.underscore, "#{agent_name}_#{action_name}" ].join("/")

          VCR.use_cassette(cassette_name) do
            response = TestAgent.response_text.generate_now

            assert_equal "text", response.format.type
            assert_nil response.message.json_object
          end
        end

        test "response format: json_object" do
          agent_name    = TestAgent.name.demodulize.underscore
          action_name   = "response_json_object"
          cassette_name = [ self.class.name.underscore, "#{agent_name}_#{action_name}" ].join("/")

          VCR.use_cassette(cassette_name) do
            response = TestAgent.response_json_object.generate_now

            assert_equal "json_object", response.format.type
            assert_not_nil response.message.json_object
          end
        end
      end
    end
  end
end
