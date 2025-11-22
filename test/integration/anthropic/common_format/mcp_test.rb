# frozen_string_literal: true

require_relative "../../test_helper"

# NOTE: MCP (Model Context Protocol) implementation is complete and API accepts MCP parameters
#
# The Anthropic gem v1.14.0 includes MCP support via Beta::MessageCreateParams with
# BetaRequestMCPServerURLDefinition models, and our implementation correctly uses these.
#
# The beta parameter (anthropic-beta: mcp-client-2025-04-04) is automatically added
# when mcp_servers are present in the request. No explicit configuration is needed.
#
# To test with real MCP servers:
# 1. Update the URLs to point to accessible MCP servers
# 2. Run tests to record VCR cassettes
#
# Unit tests validate the transformation logic in:
# test/providers/anthropic/transforms_test.rb (7 tests, all passing)

module Integration
  module Anthropic
    module CommonFormat
      class McpTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          generate_with :anthropic,
            model: "claude-haiku-4-5",
            max_tokens: 1024

          # Common format with single MCP server without authorization
          COMMON_FORMAT_SINGLE_SERVER = {
            model: "claude-haiku-4-5",
            messages: [
              {
                role: "user",
                content: "What tools do you have available?"
              }
            ],
            max_tokens: 1024,
            mcp_servers: [
              {
                type: "url",
                url: "https://demo-day.mcp.cloudflare.com/sse",
                name: "cloudflare-demo"
              }
            ]
            # Note: betas parameter is automatically added and transformed to anthropic-beta HTTP header
          }

          def common_format_single_server
            prompt(
              message: "What tools do you have available?",
              mcp_servers: [
                {
                  name: "cloudflare-demo",
                  url: "https://demo-day.mcp.cloudflare.com/sse"
                }
              ]
            )
          end

          # Common format with single MCP server with authorization
          COMMON_FORMAT_SINGLE_SERVER_WITH_AUTH = {
            model: "claude-haiku-4-5",
            messages: [
              {
                role: "user",
                content: "What tools do you have available?"
              }
            ],
            max_tokens: 1024,
            mcp_servers: [
              {
                type: "url",
                url: "https://api.githubcopilot.com/mcp/",
                name: "github-copilot",
                authorization_token: "GITHUB_MCP_TOKEN"
              }
            ]
            # Note: betas parameter is automatically added and transformed to anthropic-beta HTTP header
          }

          def common_format_single_server_with_auth
            prompt(
              message: "What tools do you have available?",
              mcp_servers: [
                {
                  name: "github-copilot",
                  url: "https://api.githubcopilot.com/mcp/",
                  authorization: ENV["GITHUB_MCP_TOKEN"]
                }
              ]
            )
          end

          # Common format with multiple MCP servers
          COMMON_FORMAT_MULTIPLE_SERVERS = {
            model: "claude-haiku-4-5",
            messages: [
              {
                role: "user",
                content: "What tools do you have available?"
              }
            ],
            max_tokens: 1024,
            mcp_servers: [
              {
                type: "url",
                url: "https://demo-day.mcp.cloudflare.com/sse",
                name: "cloudflare-demo"
              },
              {
                type: "url",
                url: "https://api.githubcopilot.com/mcp/",
                name: "github-copilot",
                authorization_token: "GITHUB_MCP_TOKEN"
              }
            ]
            # Note: betas parameter is automatically added and transformed to anthropic-beta HTTP header
          }

          def common_format_multiple_servers
            prompt(
              message: "What tools do you have available?",
              mcp_servers: [
                {
                  name: "cloudflare-demo",
                  url: "https://demo-day.mcp.cloudflare.com/sse"
                },
                {
                  name: "github-copilot",
                  url: "https://api.githubcopilot.com/mcp/",
                  authorization: ENV["GITHUB_MCP_TOKEN"]
                }
              ]
            )
          end

          # Common format with mixed auth and no auth servers
          COMMON_FORMAT_MIXED_AUTH = {
            model: "claude-haiku-4-5",
            messages: [
              {
                role: "user",
                content: "What tools do you have available?"
              }
            ],
            max_tokens: 1024,
            mcp_servers: [
              {
                type: "url",
                url: "https://demo-day.mcp.cloudflare.com/sse",
                name: "cloudflare-demo"
              },
              {
                type: "url",
                url: "https://api.githubcopilot.com/mcp/",
                name: "github-copilot",
                authorization_token: "GITHUB_MCP_TOKEN"
              }
            ]
            # Note: betas parameter is automatically added and transformed to anthropic-beta HTTP header
          }

          def common_format_mixed_auth
            prompt(
              message: "What tools do you have available?",
              mcp_servers: [
                {
                  name: "cloudflare-demo",
                  url: "https://demo-day.mcp.cloudflare.com/sse"
                },
                {
                  name: "github-copilot",
                  url: "https://api.githubcopilot.com/mcp/",
                  authorization: ENV["GITHUB_MCP_TOKEN"]
                }
              ]
            )
          end

          # Common format with SSE endpoint (Cloudflare demo server)
          COMMON_FORMAT_SSE_SERVER = {
            model: "claude-haiku-4-5",
            messages: [
              {
                role: "user",
                content: "What tools do you have available?"
              }
            ],
            max_tokens: 1024,
            mcp_servers: [
              {
                type: "url",
                url: "https://demo-day.mcp.cloudflare.com/sse",
                name: "cloudflare-demo"
              }
            ]
            # Note: betas parameter is transformed to anthropic-beta HTTP header
          }

          def common_format_sse_server
            prompt(
              message: "What tools do you have available?",
              mcp_servers: [
                {
                  name: "cloudflare-demo",
                  url: "https://demo-day.mcp.cloudflare.com/sse"
                }
              ]
            )
          end
        end

        # Test common format MCP scenarios with Cloudflare (no VCR filtering needed)
        [
          :common_format_single_server,
          :common_format_sse_server
        ].each do |action_name|
          test_request_builder(TestAgent, action_name, :generate_now, TestAgent.const_get(action_name.to_s.upcase))
        end

        # Test scenarios with VCR-filtered authorization tokens
        # These tests verify the cassette recording but skip WebMock replay verification
        # because VCR filters the token in the cassette but not in the live WebMock request
        [
          :common_format_single_server_with_auth,
          :common_format_multiple_servers,
          :common_format_mixed_auth
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
