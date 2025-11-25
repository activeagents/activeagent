# frozen_string_literal: true

require_relative "../../../test_helper"

module Integration
  module OpenAI
    module Responses
      module CommonFormat
        class McpTest < ActiveSupport::TestCase
          include Integration::TestHelper

          class TestAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-5"

            # Single MCP server without authentication
            COMMON_FORMAT_SINGLE_SERVER = {
              model: "gpt-5",
              input: "Get the current weather",
              tools: [
                {
                  type: "mcp",
                  server_label: "weather",
                  server_url: "https://demo-day.mcp.cloudflare.com/sse"
                }
              ]
            }
            def common_format_single_server
              prompt(
                input: "Get the current weather",
                mcps: [
                  { name: "weather", url: "https://demo-day.mcp.cloudflare.com/sse" }
                ]
              )
            end

            # Single MCP server with authentication
            COMMON_FORMAT_SINGLE_SERVER_WITH_AUTH = {
              model: "gpt-5",
              input: "Get repository information",
              tools: [
                {
                  type: "mcp",
                  server_label: "github_copilot",
                  server_url: "https://api.githubcopilot.com/mcp/",
                  authorization: "GITHUB_MCP_TOKEN"
                }
              ]
            }
            def common_format_single_server_with_auth
              prompt(
                input: "Get repository information",
                mcps: [
                  { name: "github_copilot", url: "https://api.githubcopilot.com/mcp/", authorization: ENV["GITHUB_MCP_TOKEN"] }
                ]
              )
            end

            # Multiple MCP servers
            COMMON_FORMAT_MULTIPLE_SERVERS = {
              model: "gpt-5",
              input: "Get the weather and repository information",
              tools: [
                {
                  type: "mcp",
                  server_label: "weather",
                  server_url: "https://demo-day.mcp.cloudflare.com/sse"
                },
                {
                  type: "mcp",
                  server_label: "github_copilot",
                  server_url: "https://api.githubcopilot.com/mcp/",
                  authorization: "GITHUB_MCP_TOKEN"
                }
              ]
            }
            def common_format_multiple_servers
              prompt(
                input: "Get the weather and repository information",
                mcps: [
                  { name: "weather", url: "https://demo-day.mcp.cloudflare.com/sse" },
                  { name: "github_copilot", url: "https://api.githubcopilot.com/mcp/", authorization: ENV["GITHUB_MCP_TOKEN"] }
                ]
              )
            end

            # MCP servers mixed with regular tools
            COMMON_FORMAT_MIXED_TOOLS_AND_MCP = {
              model: "gpt-5",
              input: "Get the weather and calculate 5 + 3",
              tools: [
                {
                  type: "function",
                  name: "calculate",
                  description: "Perform arithmetic",
                  parameters: {
                    type: "object",
                    properties: {
                      operation: { type: "string" },
                      a: { type: "number" },
                      b: { type: "number" }
                    }
                  }
                },
                {
                  type: "mcp",
                  server_label: "weather",
                  server_url: "https://demo-day.mcp.cloudflare.com/sse"
                }
              ]
            }
            def common_format_mixed_tools_and_mcp
              prompt(
                input: "Get the weather and calculate 5 + 3",
                tools: [
                  {
                    name: "calculate",
                    description: "Perform arithmetic",
                    parameters: {
                      type: "object",
                      properties: {
                        operation: { type: "string" },
                        a: { type: "number" },
                        b: { type: "number" }
                      }
                    }
                  }
                ],
                mcps: [
                  { name: "weather", url: "https://demo-day.mcp.cloudflare.com/sse" }
                ]
              )
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
          end

          ################################################################################
          # This automatically runs all the tests for the test actions
          ################################################################################

          # Tests without sensitive tokens (can use standard test_request_builder)
          [
            :common_format_single_server,
            :common_format_mixed_tools_and_mcp
          ].each do |action_name|
            test_request_builder(TestAgent, action_name, :generate_now, TestAgent.const_get(action_name.to_s.upcase, true))
          end

          # Tests with sensitive tokens need custom handling
          # These tests verify the cassette recording but skip WebMock replay verification
          # because VCR filters the token in the cassette but not in the live WebMock request
          [
            :common_format_single_server_with_auth,
            :common_format_multiple_servers
          ].each do |action_name|
            agent_name = TestAgent.name.demodulize.underscore
            expected_body = TestAgent.const_get(action_name.to_s.upcase)

            test "#{agent_name} #{action_name} Request Building" do
              cassette_name = [ self.class.name.underscore, "#{agent_name}_#{action_name}" ].join("/")

              # Run once to record response
              VCR.use_cassette(cassette_name) do
                TestAgent.send(action_name).generate_now
              end

              # Validate that the recorded request matches our expectations (with filtered values)
              cassette_file = YAML.load_file("test/fixtures/vcr_cassettes/#{cassette_name}.yml")
              saved_request_body = JSON.parse(cassette_file.dig("http_interactions", 0, "request", "body", "string"), symbolize_names: true)

              assert_equal expected_body, saved_request_body

              # Note: Skipping WebMock replay verification because VCR filters tokens in cassettes
              # but WebMock sees unfiltered tokens in live requests, causing mismatches
            end
          end
        end
      end
    end
  end
end
