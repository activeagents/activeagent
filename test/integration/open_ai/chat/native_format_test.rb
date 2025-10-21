# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module OpenAI
    module Chat
      class NativeFormatTest < ActiveSupport::TestCase
        include Integration::TestHelper

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
            "model": "gpt-4o-search-preview",
            "web_search_options": {},
            "messages": [ {
                "role": "user",
                "content": "What was a positive news story from today?"
            } ]
          }
          def web_search
            prompt(
              model: "gpt-4o-search-preview",
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

          STRUCTURED_OUTPUT = {
            "model": "gpt-4o-2024-08-06",
            "messages": [
              {
                "role": "system",
                "content": "You are an expert at structured data extraction. You will be given unstructured text from a research paper and should convert it into the given structure."
              },
              {
                "role": "user",
                "content": "The Impact of Artificial Intelligence on Modern Healthcare by Dr. Jane Smith and Dr. John Doe. This paper explores the transformative role of AI in medical diagnostics and treatment planning. Key topics include machine learning, neural networks, and predictive analytics."
              }
            ],
            "response_format": {
              "type": "json_schema",
              "json_schema": {
                "name": "research_paper_extraction",
                "schema": {
                  "type": "object",
                  "properties": {
                    "title": { "type": "string" },
                    "authors": {
                      "type": "array",
                      "items": { "type": "string" }
                    },
                    "abstract": { "type": "string" },
                    "keywords": {
                      "type": "array",
                      "items": { "type": "string" }
                    }
                  },
                  "required": [ "title", "authors", "abstract", "keywords" ],
                  "additionalProperties": false
                },
                "strict": true
              }
            }
          }
          def structured_output
            prompt(
              model: "gpt-4o-2024-08-06",
              messages: [
                {
                  role: "system",
                  content: "You are an expert at structured data extraction. You will be given unstructured text from a research paper and should convert it into the given structure."
                },
                {
                  role: "user",
                  content: "The Impact of Artificial Intelligence on Modern Healthcare by Dr. Jane Smith and Dr. John Doe. This paper explores the transformative role of AI in medical diagnostics and treatment planning. Key topics include machine learning, neural networks, and predictive analytics."
                }
              ],
              response_format: {
                type: "json_schema",
                json_schema: {
                  name: "research_paper_extraction",
                  schema: {
                    type: "object",
                    properties: {
                      title: { type: "string" },
                      authors: {
                        type: "array",
                        items: { type: "string" }
                      },
                      abstract: { type: "string" },
                      keywords: {
                        type: "array",
                        items: { type: "string" }
                      }
                    },
                    required: [ "title", "authors", "abstract", "keywords" ],
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
end
