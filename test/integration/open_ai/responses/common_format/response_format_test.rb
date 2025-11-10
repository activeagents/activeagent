# frozen_string_literal: true

require_relative "../../../test_helper"

module Integration
  module OpenAI
    module Responses
      module CommonFormat
        class ResponseFormatTest < ActiveSupport::TestCase
          include Integration::TestHelper

          class TestAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-5-nano"

            REQUEST_TEXT = {
              model: "gpt-5-nano",
              input: "List three primary colors.",
              text: { format: { type: "text" } }
            }

            def response_text_bare
              prompt(
                "List three primary colors.",
                response_format: :text
              )
            end

            def response_text
              prompt(
                "List three primary colors.",
                response_format: { type: "text" }
              )
            end

            REQUEST_JSON_OBJECT = {
              model: "gpt-5-nano",
              input: "Return a JSON object with three primary colors in an array named 'colors'.",
              text: { format: { type: "json_object" } }
            }

            def response_json_object_bare
              prompt(
                "Return a JSON object with three primary colors in an array named 'colors'.",
                response_format: :json_object
              )
            end

            def response_json_object
              prompt(
                "Return a JSON object with three primary colors in an array named 'colors'.",
                response_format: { type: "json_object" }
              )
            end

            REQUEST_JSON_SCHEMA = {
              model: "gpt-5-nano",
              input: "Return the three primary colors.",
              text: {
                format: {
                  type: "json_schema",
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

            def response_json_schema_inline
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

            def response_json_schema_implicit_bare
              prompt(
                "Return the three primary colors.",
                response_format: :json_schema
              )
            end

            def response_json_schema_implicit
              prompt(
                "Return the three primary colors.",
                response_format: { type: "json_schema" }
              )
            end

            def response_json_schema_named
              prompt(
                "Return the three primary colors.",
                response_format: { type: "json_schema", json_schema: "other" }
              )
            end
          end

          ################################################################################
          # This automatically runs all the tests for these the test actions
          ################################################################################

          [
            :response_text,
            :response_text_bare
          ].each do |action_name|
            test_request_builder(TestAgent, action_name, :generate_now, TestAgent::REQUEST_TEXT)
          end

          [
            :response_json_object,
            :response_json_object_bare
          ].each do |action_name|
            test_request_builder(TestAgent, action_name, :generate_now, TestAgent::REQUEST_JSON_OBJECT)
          end

          [
            :response_json_schema_inline,
            :response_json_schema_implicit,
            :response_json_schema_named,
            :response_json_schema_implicit_bare
          ].each do |action_name|
            test_request_builder(TestAgent, action_name, :generate_now, TestAgent::REQUEST_JSON_SCHEMA)
          end

          test "response format: text" do
            agent_name    = TestAgent.name.demodulize.underscore
            action_name   = "response_text"
            cassette_name = [ self.class.name.underscore, "#{agent_name}_#{action_name}" ].join("/")

            VCR.use_cassette(cassette_name) do
              response = TestAgent.response_text.generate_now

              assert_equal "text", response.format.type
              assert_nil response.message.parsed_json
            end
          end

          test "response format: json_object" do
            agent_name    = TestAgent.name.demodulize.underscore
            action_name   = "response_json_object"
            cassette_name = [ self.class.name.underscore, "#{agent_name}_#{action_name}" ].join("/")

            VCR.use_cassette(cassette_name) do
              response = TestAgent.response_json_object.generate_now

              assert_equal "json_object", response.format.type
              assert_not_nil response.message.parsed_json
            end
          end

          test "response format: json_schema (implicit bare)" do
            agent_name    = TestAgent.name.demodulize.underscore
            action_name   = "response_json_schema_implicit_bare"
            cassette_name = [ self.class.name.underscore, "#{agent_name}_#{action_name}" ].join("/")

            VCR.use_cassette(cassette_name) do
              response = TestAgent.response_json_schema_implicit_bare.generate_now

              assert_equal "json_schema", response.format.type
              assert_not_nil response.message.parsed_json
              assert_kind_of Array, response.message.parsed_json[:colors]
            end
          end
        end
      end
    end
  end
end
