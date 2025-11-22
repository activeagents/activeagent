# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module OpenAI
    module Responses
      class NativeFormatTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-4.1"

          TEXT_INPUT = {
            model: "gpt-4.1",
            input: "Tell me a three sentence bedtime story about a unicorn."
          }
          def text_input
            prompt(input: "Tell me a three sentence bedtime story about a unicorn.")
          end

          IMAGE_INPUT = {
            model: "gpt-4.1",
            input: [
              {
                role: "user",
                content: [
                  { type: "input_text", text: "what is in this image?" },
                  {
                    type: "input_image",
                    image_url: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
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
            model: "gpt-4.1",
            input: [
              {
                role: "user",
                content: [
                  { type: "input_text", text: "what is in this file?" },
                  {
                    type: "input_file",
                    file_url: "https://www.berkshirehathaway.com/letters/2024ltr.pdf"
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
            model: "gpt-4.1",
            tools: [ { type: "web_search_preview" } ],
            input: "What was a positive news story from today?"
          }
          def web_search
            prompt(
              tools: [ { type: "web_search_preview" } ],
              input: "What was a positive news story from today?"
            )
          end

          FILE_SEARCH = {
            model: "gpt-4.1",
            tools: [ {
              type: "file_search",
              vector_store_ids: [ "vs_1234567890" ],
              max_num_results: 20
            } ],
            input: "What are the attributes of an ancient brown dragon?"
          }
          def file_search
            prompt(
              tools: [ {
                type: "file_search",
                vector_store_ids: [ "vs_1234567890" ],
                max_num_results: 20
              } ],
              input: "What are the attributes of an ancient brown dragon?"
            )
          end

          STREAMING = {
            model: "gpt-4.1",
            instructions: "You are a helpful assistant.",
            input: "Hello!",
            stream: true
          }
          def streaming
            prompt(
              instructions: "You are a helpful assistant.",
              input: "Hello!",
              stream: true
            )
          end

          FUNCTIONS = {
            model: "gpt-4.1",
            input: "What is the weather like in Boston today?",
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
            tool_choice: "auto"
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

          def get_current_weather(location:, unit: "fahrenheit")
            { location:, unit:, temperature: "22" }
          end

          MCP_SERVER = {
            model: "gpt-4.1",
            input: "What tools do you have available?",
            tools: [
              {
                type: "mcp",
                server_label: "cloudflare-demo",
                server_url: "https://demo-day.mcp.cloudflare.com/sse"
              }
            ]
          }
          def mcp_server
            prompt(
              input: "What tools do you have available?",
              tools: [
                {
                  type: "mcp",
                  server_label: "cloudflare-demo",
                  server_url: "https://demo-day.mcp.cloudflare.com/sse"
                }
              ]
            )
          end

          REASONING = {
            model: "o3-mini",
            input: "How much wood would a woodchuck chuck?",
            reasoning: {
              effort: "high"
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

          ###############################################################
          # Extended Example
          ###############################################################
          FUNCTIONS_WITH_STREAMING = FUNCTIONS.merge(stream: true)
          def functions_with_streaming
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
          :file_input,
          :web_search,
          # :file_search,
          :streaming,
          :functions,
          :mcp_server,
          :reasoning,
          :functions_with_streaming
        ].each do |action_name|
          test_request_builder(TestAgent, action_name, :generate_now, TestAgent.const_get(action_name.to_s.upcase, true))
        end
      end
    end
  end
end
