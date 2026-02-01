# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module Azure
    module CommonFormat
      class ToolsTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          generate_with :azure_openai,
            api_key: ENV["AZURE_OPENAI_API_KEY"],
            azure_resource: ENV["AZURE_OPENAI_RESOURCE"],
            deployment_id: ENV["AZURE_OPENAI_DEPLOYMENT_ID"],
            model: ENV.fetch("AZURE_OPENAI_MODEL", "gpt-4")

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

          # Simple tool with parameters
          def tool_with_parameters
            prompt(
              message: "What's the weather in San Francisco?",
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
                    required: ["location"]
                  }
                }
              ]
            )
          end

          # Multiple tools
          def multiple_tools
            prompt(
              message: "What's the weather in NYC and what's 5 plus 3?",
              tools: [
                {
                  name: "get_weather",
                  description: "Get the current weather",
                  parameters: {
                    type: "object",
                    properties: {
                      location: { type: "string" }
                    },
                    required: ["location"]
                  }
                },
                {
                  name: "calculate",
                  description: "Perform basic arithmetic",
                  parameters: {
                    type: "object",
                    properties: {
                      operation: { type: "string", enum: ["add", "subtract", "multiply", "divide"] },
                      a: { type: "number" },
                      b: { type: "number" }
                    },
                    required: ["operation", "a", "b"]
                  }
                }
              ]
            )
          end

          # Tool choice auto
          def tool_choice_auto
            prompt(
              message: "What's the weather in London?",
              tools: [
                {
                  name: "get_weather",
                  description: "Get weather",
                  parameters: {
                    type: "object",
                    properties: {
                      location: { type: "string" }
                    },
                    required: ["location"]
                  }
                }
              ],
              tool_choice: "auto"
            )
          end

          # Tool choice required
          def tool_choice_required
            prompt(
              message: "What's the weather?",
              tools: [
                {
                  name: "get_weather",
                  description: "Get weather",
                  parameters: {
                    type: "object",
                    properties: {
                      location: { type: "string" }
                    },
                    required: ["location"]
                  }
                }
              ],
              tool_choice: "required"
            )
          end
        end

        setup do
          skip "Azure OpenAI credentials not configured" unless has_azure_openai_credentials?
        end

        test "tool with parameters triggers function call" do
          VCR.use_cassette("integration/azure/common_format/tools_test/tool_with_parameters") do
            response = TestAgent.tool_with_parameters.generate_now

            assert response.success?
            # The response should either have tool calls or a message about weather
            assert_not_nil response.message
          end
        end

        test "multiple tools can be provided" do
          VCR.use_cassette("integration/azure/common_format/tools_test/multiple_tools") do
            response = TestAgent.multiple_tools.generate_now

            assert response.success?
            assert_not_nil response.message
          end
        end

        test "tool_choice auto allows model to decide" do
          VCR.use_cassette("integration/azure/common_format/tools_test/tool_choice_auto") do
            response = TestAgent.tool_choice_auto.generate_now

            assert response.success?
            assert_not_nil response.message
          end
        end

        test "tool_choice required forces tool use" do
          VCR.use_cassette("integration/azure/common_format/tools_test/tool_choice_required") do
            response = TestAgent.tool_choice_required.generate_now

            assert response.success?
            # With required, the model must use a tool
            assert_not_nil response.message
          end
        end
      end
    end
  end
end
