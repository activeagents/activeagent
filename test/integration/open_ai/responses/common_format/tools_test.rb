# frozen_string_literal: true

require_relative "../../../test_helper"

module Integration
  module OpenAI
    module Responses
      module CommonFormat
        class ToolsTest < ActiveSupport::TestCase
          include Integration::TestHelper

          class TestAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-4.1"

            def get_weather(location:)
              { location: location, temperature: "72°F", conditions: "sunny" }
            end

            def calculate(operation:, a:, b:)
              result = case operation
              when "add" then a + b
              when "subtract" then a - b
              when "multiply" then a * b
              when "divide" then a / b
              end
              { operation: operation, a: a, b: b, result: result }
            end

            # Common format with 'parameters' key (recommended)
            COMMON_FORMAT_PARAMETERS = {
              model: "gpt-4.1",
              input: "What's the weather in San Francisco?",
              tools: [
                {
                  type: "function",
                  name: "get_weather",
                  description: "Get the current weather in a given location",
                  parameters: {
                    type: "object",
                    properties: {
                      location: {
                        type: "string",
                        description: "The city and state, e.g. San Francisco, CA"
                      }
                    },
                    required: [ "location" ]
                  }
                }
              ],
              tool_choice: "auto"
            }
            def common_format_parameters
              prompt(
                input: "What's the weather in San Francisco?",
                tools: [
                  {
                    name: "get_weather",
                    description: "Get the current weather in a given location",
                    parameters: {
                      type: "object",
                      properties: {
                        location: {
                          type: "string",
                          description: "The city and state, e.g. San Francisco, CA"
                        }
                      },
                      required: [ "location" ]
                    }
                  }
                ],
                tool_choice: "auto"
              )
            end

            # Common format with 'input_schema' key (Anthropic-style)
            COMMON_FORMAT_INPUT_SCHEMA = {
              model: "gpt-4.1",
              input: "What's the weather in Boston?",
              tools: [
                {
                  type: "function",
                  name: "get_weather",
                  description: "Get the current weather in a given location",
                  parameters: {
                    type: "object",
                    properties: {
                      location: {
                        type: "string",
                        description: "The city and state, e.g. San Francisco, CA"
                      }
                    },
                    required: [ "location" ]
                  }
                }
              ],
              tool_choice: "auto"
            }
            def common_format_input_schema
              prompt(
                input: "What's the weather in Boston?",
                tools: [
                  {
                    name: "get_weather",
                    description: "Get the current weather in a given location",
                    input_schema: {
                      type: "object",
                      properties: {
                        location: {
                          type: "string",
                          description: "The city and state, e.g. San Francisco, CA"
                        }
                      },
                      required: [ "location" ]
                    }
                  }
                ],
                tool_choice: "auto"
              )
            end

            # Multiple tools in common format
            COMMON_FORMAT_MULTIPLE_TOOLS = {
              model: "gpt-4.1",
              input: "What's the weather in NYC and what's 5 plus 3?",
              tools: [
                {
                  type: "function",
                  name: "get_weather",
                  description: "Get the current weather",
                  parameters: {
                    type: "object",
                    properties: {
                      location: { type: "string" }
                    },
                    required: [ "location" ]
                  }
                },
                {
                  type: "function",
                  name: "calculate",
                  description: "Perform basic arithmetic",
                  parameters: {
                    type: "object",
                    properties: {
                      operation: { type: "string", enum: [ "add", "subtract", "multiply", "divide" ] },
                      a: { type: "number" },
                      b: { type: "number" }
                    },
                    required: [ "operation", "a", "b" ]
                  }
                }
              ],
              tool_choice: "auto"
            }
            def common_format_multiple_tools
              prompt(
                input: "What's the weather in NYC and what's 5 plus 3?",
                tools: [
                  {
                    name: "get_weather",
                    description: "Get the current weather",
                    parameters: {
                      type: "object",
                      properties: {
                        location: { type: "string" }
                      },
                      required: [ "location" ]
                    }
                  },
                  {
                    name: "calculate",
                    description: "Perform basic arithmetic",
                    parameters: {
                      type: "object",
                      properties: {
                        operation: { type: "string", enum: [ "add", "subtract", "multiply", "divide" ] },
                        a: { type: "number" },
                        b: { type: "number" }
                      },
                      required: [ "operation", "a", "b" ]
                    }
                  }
                ],
                tool_choice: "auto"
              )
            end

            # Tool choice - string format
            COMMON_FORMAT_TOOL_CHOICE_AUTO = {
              model: "gpt-4.1",
              input: "What's the weather?",
              tools: [
                {
                  type: "function",
                  name: "get_weather",
                  description: "Get weather",
                  parameters: {
                    type: "object",
                    properties: {
                      location: { type: "string" }
                    },
                    required: [ "location" ]
                  }
                }
              ],
              tool_choice: "auto"
            }
            def common_format_tool_choice_auto
              prompt(
                input: "What's the weather?",
                tools: [
                  {
                    name: "get_weather",
                    description: "Get weather",
                    parameters: {
                      type: "object",
                      properties: {
                        location: { type: "string" }
                      },
                      required: [ "location" ]
                    }
                  }
                ],
                tool_choice: "auto"
              )
            end

            # Tool choice - force tool use with "required"
            COMMON_FORMAT_TOOL_CHOICE_REQUIRED = {
              model: "gpt-4.1",
              input: "What's the weather?",
              tools: [
                {
                  type: "function",
                  name: "get_weather",
                  description: "Get weather",
                  parameters: {
                    type: "object",
                    properties: {
                      location: { type: "string" }
                    },
                    required: [ "location" ]
                  }
                }
              ],
              tool_choice: "required"
            }
            def common_format_tool_choice_required
              prompt(
                input: "What's the weather?",
                tools: [
                  {
                    name: "get_weather",
                    description: "Get weather",
                    parameters: {
                      type: "object",
                      properties: {
                        location: { type: "string" }
                      },
                      required: [ "location" ]
                    }
                  }
                ],
                tool_choice: "required"
              )
            end

            # Tool choice - specific tool
            COMMON_FORMAT_TOOL_CHOICE_SPECIFIC = {
              model: "gpt-4.1",
              input: "What's the weather?",
              tools: [
                {
                  type: "function",
                  name: "get_weather",
                  description: "Get weather",
                  parameters: {
                    type: "object",
                    properties: {
                      location: { type: "string" }
                    },
                    required: [ "location" ]
                  }
                }
              ],
              tool_choice: {
                type: "function",
                name: "get_weather"
              }
            }
            def common_format_tool_choice_specific
              prompt(
                input: "What's the weather?",
                tools: [
                  {
                    name: "get_weather",
                    description: "Get weather",
                    parameters: {
                      type: "object",
                      properties: {
                        location: { type: "string" }
                      },
                      required: [ "location" ]
                    }
                  }
                ],
                tool_choice: { name: "get_weather" }
              )
            end
          end

          ################################################################################
          # This automatically runs all the tests for the test actions
          ################################################################################
          [
            :common_format_parameters,
            :common_format_input_schema,
            :common_format_multiple_tools,
            :common_format_tool_choice_auto,
            :common_format_tool_choice_required,
            :common_format_tool_choice_specific
          ].each do |action_name|
            test_request_builder(TestAgent, action_name, :generate_now, TestAgent.const_get(action_name.to_s.upcase, true))
          end
        end
      end
    end
  end
end
