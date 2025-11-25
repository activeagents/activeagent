require "test_helper"

module Docs
  module Actions
    class McpsExamplesTest < ActiveSupport::TestCase
      class QuickStartExample < ActiveSupport::TestCase
        # region quick_start_weather_agent
        class WeatherAgent < ActiveAgent::Base
          generate_with :anthropic, model: "claude-haiku-4-5"

          def forecast
            prompt(
              "What's the weather like?",
              mcps: [ { name: "weather", url: "https://demo-day.mcp.cloudflare.com/sse" } ]
            )
          end
        end
        # endregion quick_start_weather_agent

        test "quick start weather agent with mcps" do
          VCR.use_cassette("docs/actions/mcps/quick_start_weather") do
            response = WeatherAgent.forecast.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class SingleServerExample < ActiveSupport::TestCase
        # region single_server_data_agent
        class DataAgent < ActiveAgent::Base
          generate_with :anthropic, model: "claude-haiku-4-5"

          def analyze
            prompt(
              "Analyze the latest data",
              mcps: [ { name: "cloudflare-demo", url: "https://demo-day.mcp.cloudflare.com/sse" } ]
            )
          end
        end
        # endregion single_server_data_agent

        test "single server MCP connection" do
          VCR.use_cassette("docs/actions/mcps/single_server") do
            response = DataAgent.analyze.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class MultipleServersExample < ActiveSupport::TestCase
        # region multiple_servers_integrated_agent
        class IntegratedAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-4o"

          def research
            prompt(
              "Research the latest AI developments",
              mcps: [
                { name: "cloudflare", url: "https://demo-day.mcp.cloudflare.com/sse" },
                { name: "github", url: "https://api.githubcopilot.com/mcp/", authorization: ENV["GITHUB_MCP_TOKEN"] }
              ]
            )
          end
        end
        # endregion multiple_servers_integrated_agent

        test "multiple MCP servers connection" do
          VCR.use_cassette("docs/actions/mcps/multiple_servers") do
            response = IntegratedAgent.research.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class WithFunctionToolsExample < ActiveSupport::TestCase
        # region hybrid_agent_with_tools
        class HybridAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-4o"

          def analyze_data
            prompt(
              "Calculate and fetch data",
              tools: [ {
                name: "calculate",
                description: "Perform calculations",
                parameters: {
                  type: "object",
                  properties: {
                    operation: { type: "string" },
                    a: { type: "number" },
                    b: { type: "number" }
                  }
                }
              } ],
              mcps: [ { name: "data-service", url: "https://demo-day.mcp.cloudflare.com/sse" } ]
            )
          end

          def calculate(operation:, a:, b:)
            case operation
            when "add" then a + b
            when "subtract" then a - b
            end
          end
        end
        # endregion hybrid_agent_with_tools

        test "MCP with function tools" do
          VCR.use_cassette("docs/actions/mcps/with_function_tools") do
            response = HybridAgent.analyze_data.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class OpenAIPrebuiltConnectorsExample < ActiveSupport::TestCase
        # region openai_prebuilt_connectors
        class FileAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-4o"

          def search_files
            prompt(
              input: "Find documents about Q4 revenue",
              mcps: [ { name: "dropbox", url: "mcp://dropbox" } ]  # Pre-built connector
            )
          end
        end
        # endregion openai_prebuilt_connectors

        test "OpenAI pre-built connectors" do
          skip "Pre-built connectors require real OAuth tokens"
          # This example is for documentation purposes only
          # Real testing would require actual Dropbox OAuth setup
        end
      end

      class OpenAICustomServersExample < ActiveSupport::TestCase
        # region openai_custom_servers
        class CustomAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-4o"

          def custom_tools
            prompt(
              input: "Use custom tools",
              mcps: [ { name: "github_copilot", url: "https://api.githubcopilot.com/mcp/", authorization: ENV["GITHUB_MCP_TOKEN"] } ]
            )
          end
        end
        # endregion openai_custom_servers

        test "OpenAI custom MCP servers" do
          VCR.use_cassette("docs/actions/mcps/openai_custom_servers") do
            response = CustomAgent.custom_tools.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class AnthropicBasicExample < ActiveSupport::TestCase
        # region anthropic_basic_mcp
        class ClaudeAgent < ActiveAgent::Base
          generate_with :anthropic, model: "claude-haiku-4-5"

          def use_mcp
            prompt(
              message: "What tools are available?",
              mcps: [ { name: "demo-server", url: "https://demo-day.mcp.cloudflare.com/sse" } ]
            )
          end
        end
        # endregion anthropic_basic_mcp

        test "Anthropic basic MCP usage" do
          VCR.use_cassette("docs/actions/mcps/anthropic_basic") do
            response = ClaudeAgent.use_mcp.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end

      class NativeFormatsExample < ActiveSupport::TestCase
        # region native_formats_openai
        class OpenAINativeAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-4o"

          def native_format
            prompt(
              input: "What can you do?",
              tools: [ {
                type: "mcp",
                server_label: "github",
                server_url: "https://api.githubcopilot.com/mcp/",
                authorization: ENV["GITHUB_MCP_TOKEN"]
              } ]
            )
          end
        end
        # endregion native_formats_openai

        # region native_formats_anthropic
        class AnthropicNativeAgent < ActiveAgent::Base
          generate_with :anthropic, model: "claude-haiku-4-5"

          def native_format
            prompt(
              message: "What can you do?",
              mcp_servers: [ {
                type: "url",
                name: "cloudflare",
                url: "https://demo-day.mcp.cloudflare.com/sse"
              } ]
            )
          end
        end
        # endregion native_formats_anthropic

        test "native format OpenAI" do
          VCR.use_cassette("docs/actions/mcps/native_format_openai") do
            response = OpenAINativeAgent.native_format.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end

        test "native format Anthropic" do
          VCR.use_cassette("docs/actions/mcps/native_format_anthropic") do
            response = AnthropicNativeAgent.native_format.generate_now

            assert response.message.content.present?

            doc_example_output(response)
          end
        end
      end
    end
  end
end
