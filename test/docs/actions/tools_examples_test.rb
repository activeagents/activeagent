require "test_helper"

module Docs
  module Actions
    class ToolsExamplesTest < ActiveSupport::TestCase
      class QuickStartExample < ActiveSupport::TestCase
        # region quick_start_weather_agent
        class WeatherAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o"

          def weather_update
            prompt(
              input: "What's the weather in Boston?",
              tools: [ {
                name: "get_weather",
                description: "Get current weather for a location",
                parameters: {
                  type: "object",
                  properties: {
                    location: { type: "string", description: "City and state" }
                  },
                  required: [ "location" ]
                }
              } ]
            )
          end

          def get_weather(location:)
            { location: location, temperature: "72°F", conditions: "sunny" }
          end
        end
        # endregion quick_start_weather_agent

        test "quick start weather agent with tools" do
          VCR.use_cassette("docs/actions/tools/quick_start_weather") do
            # region quick_start_weather_usage
            response = WeatherAgent.weather_update.generate_now
            # endregion quick_start_weather_usage

            assert response.message.content.present?
            assert response.message.content.include?("72")

            doc_example_output(response)
          end
        end
      end

      class OpenAIBasicExample < ActiveSupport::TestCase
        # region openai_basic_function
        class WeatherAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o"

          def weather_update
            prompt(
              input: "What's the weather in Boston?",
              tools: [ {
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
              } ]
            )
          end

          def get_current_weather(location:, unit: "fahrenheit")
            { location: location, unit: unit, temperature: "22", conditions: "sunny" }
          end
        end
        # endregion openai_basic_function

        test "OpenAI basic function registration" do
          VCR.use_cassette("docs/actions/tools/openai_basic_function") do
            response = WeatherAgent.weather_update.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class AnthropicBasicExample < ActiveSupport::TestCase
        # region anthropic_basic_function
        class WeatherAgent < ApplicationAgent
          generate_with :anthropic, model: "claude-sonnet-4-20250514"

          def weather_update
            prompt(
              message: "What's the weather in San Francisco?",
              max_tokens: 1024,
              tools: [ {
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
              } ]
            )
          end

          def get_weather(location:)
            { location: location, temperature: "72°F", conditions: "sunny" }
          end
        end
        # endregion anthropic_basic_function

        test "Anthropic basic function registration" do
          VCR.use_cassette("docs/actions/tools/anthropic_basic_function") do
            response = AnthropicBasicExample::WeatherAgent.weather_update.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class OllamaBasicExample < ActiveSupport::TestCase
        # region ollama_basic_function
        class WeatherAgent < ApplicationAgent
          generate_with :ollama, model: "qwen3:latest"

          def weather_update
            prompt(
              message: "What's the weather in Boston?",
              tools: [ {
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
              } ]
            )
          end

          def get_current_weather(location:, unit: "fahrenheit")
            { location: location, unit: unit, temperature: "22" }
          end
        end
        # endregion ollama_basic_function

        test "Ollama basic function registration" do
          VCR.use_cassette("docs/actions/tools/ollama_basic_function") do
            response = OllamaBasicExample::WeatherAgent.weather_update.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class OpenRouterBasicExample < ActiveSupport::TestCase
        # region openrouter_basic_function
        class WeatherAgent < ApplicationAgent
          generate_with :openrouter, model: "google/gemini-2.0-flash-001"

          def weather_update
            prompt(
              message: "What's the weather in Boston?",
              tools: [ {
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
              } ]
            )
          end

          def get_current_weather(location:, unit: "fahrenheit")
            { location: location, unit: unit, temperature: "22" }
          end
        end
        # endregion openrouter_basic_function

        test "OpenRouter basic function registration" do
          VCR.use_cassette("docs/actions/tools/openrouter_basic_function") do
            response = OpenRouterBasicExample::WeatherAgent.weather_update.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class CrossProviderExample < ActiveSupport::TestCase
        test "cross provider usage" do
          VCR.use_cassette("docs/actions/tools/cross_provider_usage") do
            # region cross_provider_module
            # Define once, use with any provider
            module WeatherTool
              extend ActiveSupport::Concern

              WEATHER_TOOL = {
                name: "get_weather",
                description: "Get current weather for a location",
                parameters: {
                  type: "object",
                  properties: {
                    location: { type: "string", description: "City and state" },
                    unit: { type: "string", enum: [ "celsius", "fahrenheit" ] }
                  },
                  required: [ "location" ]
                }
              }

              def get_current_weather(location:, unit: "fahrenheit")
                { location: location, unit: unit, temperature: "22" }
              end
            end
            # endregion cross_provider_module

            # region cross_provider_openai
            class OpenAIAgent < ApplicationAgent
              include WeatherTool
              generate_with :openai, model: "gpt-4o"

              def check_weather
                prompt(input: "What's the weather?", tools: [ WEATHER_TOOL ])
              end
            end
            # endregion cross_provider_openai

            # region cross_provider_anthropic
            class AnthropicAgent < ApplicationAgent
              include WeatherTool
              generate_with :anthropic, model: "claude-sonnet-4-20250514"

              def check_weather
                prompt(message: "What's the weather?", tools: [ WEATHER_TOOL ])
              end
            end
            # endregion cross_provider_anthropic

            # region cross_provider_ollama
            class OllamaAgent < ApplicationAgent
              include WeatherTool
              generate_with :ollama, model: "qwen3:latest"

              def check_weather
                prompt(message: "What's the weather?", tools: [ WEATHER_TOOL ])
              end
            end
            # endregion cross_provider_ollama

            # region cross_provider_openrouter
            class OpenRouterAgent < ApplicationAgent
              include WeatherTool
              generate_with :openrouter, model: "google/gemini-2.0-flash-001"

              def check_weather
                prompt(message: "What's the weather?", tools: [ WEATHER_TOOL ])
              end
            end
            # endregion cross_provider_openrouter

            response = OpenAIAgent.check_weather.generate_now
            assert response.message.content.present?

            response = AnthropicAgent.check_weather.generate_now
            assert response.message.content.present?

            response = OllamaAgent.check_weather.generate_now
            assert response.message.content.present?

            response = OpenRouterAgent.check_weather.generate_now
            assert response.message.content.present?
          end
        end
      end
    end
  end
end
