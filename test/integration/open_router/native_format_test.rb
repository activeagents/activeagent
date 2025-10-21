# frozen_string_literal: true

require_relative "../test_helper"

module Integration
  module OpenRouter
    class NativeFormatTest < ActiveSupport::TestCase
      include Integration::TestHelper

      class TestAgent < ActiveAgent::Base
        generate_with :open_router, model: nil

        ###############################################################
        # OpenAI Provided Example
        ###############################################################
        TEXT_INPUT = {
          "model": "openrouter/auto",
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
          "model": "openai/gpt-5",
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
          ]
        }
        def image_input
          prompt(
            model: "openai/gpt-5",
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
            ]
          )
        end

        STREAMING = {
          "model": "openrouter/auto",
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
          "model": "google/gemini-2.0-flash-001",
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
            model: "google/gemini-2.0-flash-001",
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

        def get_current_weather(location:, unit: "fahrenheit")
          { location:, unit:, temperature: "22" }
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

        WEB_SEARCH = {
          "model": "openrouter/auto",
          "web_search_options": {},
          "messages": [ {
              "role": "user",
              "content": "What was a positive news story from today?"
          } ]
        }
        def web_search
          prompt(
            model: "openrouter/auto",
            web_search_options: {},
            messages: [ {
                role: "user",
                content: "What was a positive news story from today?"
            } ],
          )
        end

        ###############################################################
        # Extended Example
        ###############################################################
        STRUCTURED_OUTPUT = {
          "model": "openai/gpt-4o",
          "messages": [
            {
              "role": "user",
              "content": "What is the weather like in London?"
            }
          ],
          "response_format": {
            "type": "json_schema",
            "json_schema": {
              "name": "weather",
              "strict": true,
              "schema": {
                "type": "object",
                "properties": {
                  "location": {
                    "type": "string",
                    "description": "City or location name"
                  },
                  "temperature": {
                    "type": "number",
                    "description": "Temperature in Celsius"
                  },
                  "conditions": {
                    "type": "string",
                    "description": "Weather conditions description"
                  }
                },
                "required": [ "location", "temperature", "conditions" ],
                "additionalProperties": false
              }
            }
          }
        }
        def structured_output
          prompt(
            model: "openai/gpt-4o",
            messages: [
              {
                role: "user",
                content: "What is the weather like in London?"
              }
            ],
            response_format: {
              type: "json_schema",
              json_schema: {
                name: "weather",
                strict: true,
                schema: {
                  type: "object",
                  properties: {
                    location: {
                      type: "string",
                      description: "City or location name"
                    },
                    temperature: {
                      type: "number",
                      description: "Temperature in Celsius"
                    },
                    conditions: {
                      type: "string",
                      description: "Weather conditions description"
                    }
                  },
                  required: [ "location", "temperature", "conditions" ],
                  additionalProperties: false
                }
              }
            }
          )
        end

        FUNCTIONS_WITH_STREAMING = FUNCTIONS.merge(stream: true)
        def functions_with_streaming
          prompt(
            model: "google/gemini-2.0-flash-001",
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

      ################################################################################
      # This automatically runs all the tests for these the test actions
      ################################################################################
      [
        :text_input,
        :image_input,
        :streaming,
        :functions,
        :logprobs,
        :web_search,
        :structured_output,
        :functions_with_streaming
      ].each do |action_name|
        test_request_builder(TestAgent, action_name, :generate_now, TestAgent.const_get(action_name.to_s.upcase, true))
      end
    end
  end
end
