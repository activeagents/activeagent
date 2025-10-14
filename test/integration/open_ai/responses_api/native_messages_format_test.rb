# frozen_string_literal: true

require "test_helper"

module Integration
  module OpenAI
    module ResponsesAPI
      class NativeMessagesFormatTest < ActiveSupport::TestCase
        include WebMock

        class TestAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-4.1"

          TEXT_INPUT = {
            "model": "gpt-4.1",
            "input": "Tell me a three sentence bedtime story about a unicorn."
          }
          def text_input
            prompt(input: "Tell me a three sentence bedtime story about a unicorn.")
          end

          IMAGE_INPUT = {
            "model": "gpt-4.1",
            "input": [
              {
                "role": "user",
                "content": [
                  { "type": "input_text", "text": "what is in this image?" },
                  {
                    "type": "input_image",
                    "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
                  }
                ]
              }
            ]
          }
          def image_input
            prompt(input: {
              role: :user,
              content: [
                {
                  type: "input_text",
                  text: "what is in this image?"
                },
                {
                  type: "input_image",
                  image_url: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
                }
              ]
            })
          end

          FILE_INPUT = {
            "model": "gpt-4.1",
            "input": [
              {
                "role": "user",
                "content": [
                  { "type": "input_text", "text": "what is in this file?" },
                  {
                    "type": "input_file",
                    "file_url": "https://www.berkshirehathaway.com/letters/2024ltr.pdf"
                  }
                ]
              }
            ]
          }
          def file_input
            prompt(input: {
              role: "user",
              content: [
                {
                  type: "input_text",
                  text: "what is in this file?"
                },
                {
                  type: "input_file",
                  file_url: "https://www.berkshirehathaway.com/letters/2024ltr.pdf"
                }
              ]
            })
          end

          WEB_SEARCH = {
            "model": "gpt-4.1",
            "tools": [ { "type": "web_search_preview" } ],
            "input": "What was a positive news story from today?"
          }
          def web_search
            prompt(
              tools: [ { type: "web_search_preview" } ],
              input: "What was a positive news story from today?"
            )
          end

          FILE_SEARCH = {
            "model": "gpt-4.1",
            "tools": [ {
              "type": "file_search",
              "vector_store_ids": [ "vs_1234567890" ],
              "max_num_results": 20
            } ],
            "input": "What are the attributes of an ancient brown dragon?"
          }
          def file_search
            prompt(
              tools: [ {
                "type": "file_search",
                "vector_store_ids": [ "vs_1234567890" ],
                "max_num_results": 20
              } ],
              input: "What are the attributes of an ancient brown dragon?"
            )
          end

          STREAMING = {
            "model": "gpt-4.1",
            "instructions": "You are a helpful assistant.",
            "input": "Hello!",
            "stream": true
          }
          def streaming
            prompt(
              instructions: "You are a helpful assistant.",
              input: "Hello!",
              stream: true
            )
          end

          FUNCTIONS = {
            "model": "gpt-4.1",
            "input": "What is the weather like in Boston today?",
            "tools": [
              {
                "type": "function",
                "name": "get_current_weather",
                "description": "Get the current weather in a given location",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "location": {
                      "type": "string",
                      "description": "The city and state, e.g. San Francisco, CA"
                    },
                    "unit": {
                      "type": "string",
                      "enum": [ "celsius", "fahrenheit" ]
                    }
                  },
                  "required": [ "location", "unit" ]
                }
              }
            ],
            "tool_choice": "auto"
          }
          def functions
            prompt(
              input: "What is the weather like in Boston today?",
              tools: [ {
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
              } ],
              tool_choice: "auto"
            )
          end

          REASONING = {
            "model": "o3-mini",
            "input": "How much wood would a woodchuck chuck?",
            "reasoning": {
              "effort": "high"
            }
          }
          def reasoning
            prompt(
              model: "o3-mini",
              input: "How much wood would a woodchuck chuck?",
              reasoning: {
                effort: "high"
              }
            )
          end
        end

        def cassette_name(action_name)
          "open_ai/responses_api/native_messages_format/#{action_name}"
        end

        def compare_cassette(action_name)
                    expected_body = TestAgent.const_get(action_name.to_s.upcase, false)
          assert_equal expected_body.deep_stringify_keys, JSON.parse(request_body)
        end

        def cassette_load(action_name)
          filename = "test/fixtures/vcr_cassettes/#{cassette_name(action_name)}.yml"
          cassette = YAML.load_file(filename)

          cassette.dig("http_interactions")
        end

        ################################################################################
        # This automatically runs all the tests for these the test actions
        ################################################################################
        [
          :text_input,
          :image_input,
          :file_input,
          :web_search,
          # :file_search,
          # :streaming,
          # :functions,
          :reasoning
        ].each do |action_name|
          test "#{action_name}" do
            # Run Once to Record Response & Smoke Test
            VCR.use_cassette(cassette_name(action_name)) do
              response = TestAgent.send(action_name).generate_now

              assert_not_nil response.message.content
            end

            # Run Again to Validate that the Request is well formed and not mutated
            cassette = cassette_load(action_name)
            request_method = cassette.dig(0, "request", "method").to_sym
            request_uri    = cassette.dig(0, "request", "uri")
            response_body  = cassette.dig(0, "response", "body", "string")

            stub_request(request_method, request_uri).to_return(body: response_body)
            TestAgent.send(action_name).generate_now
            assert_requested request_method, request_uri, body: TestAgent.const_get(action_name.to_s.upcase, false), times: 2
          end
        end
      end
    end
  end
end
