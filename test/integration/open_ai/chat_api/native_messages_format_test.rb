# frozen_string_literal: true

require "test_helper"

module Integration
  module OpenAI
    module ChatAPI
      class NativeMessagesFormatTest < ActiveSupport::TestCase
        include WebMock

        class TestAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-5", api_version: :chat

          ###############################################################
          # OpenAI Provided Example
          ###############################################################

          TEXT_INPUT = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "developer",
                "content": "You are a helpful assistant."
              },
              {
                "role": "user",
                "content": "Hello!"
              }
            ]
          }
          def text_input
            prompt(
              messages: [
                {
                  role: "developer",
                  content: "You are a helpful assistant."
                },
                {
                  role: "user",
                  content: "Hello!"
                }
              ]
            )
          end

          IMAGE_INPUT = {
            "model": "gpt-4.1",
            "messages": [
              {
                "role": "user",
                "content": [
                  {
                    "type": "text",
                    "text": "What is in this image?"
                  },
                  {
                    "type": "image_url",
                    "image_url": {
                      "url": "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
                    }
                  }
                ]
              }
            ],
            "max_tokens": 300
          }
          def image_input
            prompt(
              model: "gpt-4.1",
              messages: [
                {
                  role: "user",
                  content: [
                    {
                      type: "text",
                      text: "What is in this image?"
                    },
                    {
                      type: "image_url",
                      image_url: {
                        url: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
                      }
                    }
                  ]
                }
              ],
              max_tokens: 300
            )
          end

          STREAMING = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "developer",
                "content": "You are a helpful assistant."
              },
              {
                "role": "user",
                "content": "Hello!"
              }
            ],
            "stream": true
          }
          def streaming
            prompt(
              messages: [
                {
                  role: "developer",
                  content: "You are a helpful assistant."
                },
                {
                  role: "user",
                  content: "Hello!"
                }
              ],
              stream: true
            )
          end

          FUNCTIONS = {
            "model": "gpt-4.1",
            "messages": [
              {
                "role": "user",
                "content": "What is the weather like in Boston today?"
              }
            ],
            "tools": [
              {
                "type": "function",
                "function": {
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
                    "required": [ "location" ]
                  }
                }
              }
            ],
            "tool_choice": "auto"
          }
          def functions
            prompt(
              model: "gpt-4.1",
              messages: [
              {
                role: "user",
                content: "What is the weather like in Boston today?"
              }
              ],
              tools: [
              {
                type: "function",
                function: {
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
                  required: [ "location" ]
                }
                }
              }
              ],
              tool_choice: "auto"
            )
          end

          LOGPROBS = {
            "model": "gpt-4",
            "messages": [
              {
                "role": "user",
                "content": "Hello!"
              }
            ],
            "logprobs": true,
            "top_logprobs": 2
          }
          def logprobs
            prompt(
              model: "gpt-4",
              messages: [
                {
                  role: "user",
                  content: "Hello!"
                }
              ],
              logprobs: true,
              top_logprobs: 2
            )
          end

          ###############################################################
          # Extended Example
          ###############################################################
          FUNCTIONS_WITH_STREAMING = FUNCTIONS.merge(stream: true)
          def functions_with_streaming
            prompt(
              model: "gpt-4.1",
              messages: [
              {
                role: "user",
                content: "What is the weather like in Boston today?"
              }
              ],
              tools: [
              {
                type: "function",
                function: {
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
                  required: [ "location" ]
                }
                }
              }
              ],
              tool_choice: "auto",
              stream: true
            )
          end
        end

        def cassette_name(action_name)
          "open_ai/chat_api/native_messages_format/#{action_name}"
        end

        def cassette_load(cassette_name)
          filename = "test/fixtures/vcr_cassettes/#{cassette_name}.yml"
          cassette = YAML.load_file(filename)

          cassette.dig("http_interactions")
        end

        ################################################################################
        # This automatically runs all the tests for these the test actions
        ################################################################################
        def runner(cassette_name, request_body, &block)
          # Run Once to Record Response & Smoke Test
          VCR.use_cassette(cassette_name) do
            response = block.call

            if request_body[:stream]
              assert_nil response.message.content.presence
            else
              assert_not_nil response.message.content.presence
            end
          end

          # Run Again to Validate that the Request is well formed and not mutated
          cassette = cassette_load(cassette_name)
          request_method = cassette.dig(0, "request", "method").to_sym
          request_uri    = cassette.dig(0, "request", "uri")
          response_body  = cassette.dig(0, "response", "body", "string")

          stub_request(request_method, request_uri).to_return(body: response_body)
          block.call
          assert_requested request_method, request_uri, body: request_body, times: 2
        end

        [
          # :text_input,
          # :image_input,
          # :streaming,
          :functions
          # :functions_with_streaming
          # :logprobs
        ].each do |action_name|
          test "#{action_name}" do
            cassette_name = cassette_name(action_name)
            request_body  = TestAgent.const_get(action_name.to_s.upcase, false)
            runner(cassette_name, request_body) do
              TestAgent.send(action_name).generate_now
            end
          end
        end
      end
    end
  end
end
