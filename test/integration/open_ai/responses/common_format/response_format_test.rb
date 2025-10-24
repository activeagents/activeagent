# frozen_string_literal: true

require_relative "../../../test_helper"

module Integration
  module OpenAI
    module CommonFormat
      class ResponseFormatTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-5-nano"

          RESPONSE_TEXT = {
            model: "gpt-5-nano",
            input: "List three primary colors.",
            text: { format: { type: "text" } }
          }
          def response_text
            prompt(
              "List three primary colors.",
              response_format: { type: "text" }
            )
          end

          RESPONSE_JSON_OBJECT = {
            model: "gpt-5-nano",
            input: "Return a JSON object with three primary colors in an array named 'colors'.",
            text: { format: { type: "json_object" } }
          }
          def response_json_object
            prompt(
              "Return a JSON object with three primary colors in an array named 'colors'.",
              response_format: { type: "json_object" }
            )
          end

          RESPONSE_JSON_SCHEMA = {
            model: "gpt-5-nano",
            input: "Return the three primary colors.",
            text: {
              format: {
                type: "json_schema",
                json_schema: {
                  name: "primary_colors",
                  schema: {
                    type: "object",
                    properties: {
                      colors: {
                        type: "array",
                        items: { type: "string" }
                      }
                    },
                    required: [ "colors" ],
                    additionalProperties: false
                  },
                  strict: true
                }
              }
            }
          }
          def response_json_schema
            prompt(
              "Return the three primary colors.",
              response_format: {
                type: "json_schema",
                json_schema: {
                  name: "primary_colors",
                  schema: {
                    type: "object",
                    properties: {
                      colors: {
                        type: "array",
                        items: { type: "string" }
                      }
                    },
                    required: [ "colors" ],
                    additionalProperties: false
                  },
                  strict: true
                }
              }
            )
          end
        end

        ################################################################################
        # This automatically runs all the tests for these the test actions
        ################################################################################
        [
          :response_text,
          :response_json_object
          # :response_json_schema # TODO: FIX ME
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

        test "response format: json_schema" do
          skip("FIX ME")

          agent_name    = TestAgent.name.demodulize.underscore
          action_name   = "response_json_schema"
          cassette_name = [ self.class.name.underscore, "#{agent_name}_#{action_name}" ].join("/")

          VCR.use_cassette(cassette_name) do
            response = TestAgent.response_json_schema.generate_now

            assert_equal "json_schema", response.format.type
            assert_not_nil response.message.json_object
            assert_kind_of Array, response.message.json_object["colors"]
          end
        end
      end
    end
  end
end
