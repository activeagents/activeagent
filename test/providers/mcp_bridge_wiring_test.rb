# frozen_string_literal: true

require "test_helper"
require "mcp"
require "active_agent/providers/deepseek_provider"
require "active_agent/providers/anthropic_provider"

# How a provider adopts the bridge for `mcps:`, and — as important — that a
# provider which runs MCP itself is left alone. The bridge is opt-in so that
# nothing changes for providers whose `mcp_servers` works.
class MCPBridgeWiringTest < ActiveSupport::TestCase
  MCP_SERVERS = [ { name: "firecrawl", url: "https://mcp.example.com/mcp" } ].freeze
  MESSAGES    = [ { role: "user", content: "Fetch https://example.com" } ].freeze

  # Only `tools` is needed here — the bridge's call path is covered by
  # MCPBridgeTest.
  class FakeClient
    def tools
      [ MCP::Client::Tool.new(name: "get_page", description: "Fetch a page", input_schema: nil) ]
    end
  end

  test "DeepSeek serves mcps: from the client side" do
    assert_predicate deepseek(mcps: MCP_SERVERS), :client_side_mcp?
  end

  test "a provider that runs MCP itself does not" do
    assert_not_predicate anthropic(mcps: MCP_SERVERS), :client_side_mcp?
  end

  test "DeepSeek turns mcps: into tools and drops the declaration" do
    provider = deepseek(mcps: MCP_SERVERS)

    with_bridge do
      context = provider.send(:prompt_context)

      assert_not context.key?(:mcps), "the declaration must not reach a provider that cannot accept it"

      request = provider.prompt_request_type.cast(context.except(:trace_id)).serialize

      assert_not request.key?(:mcp_servers), "DeepSeek ignores mcp_servers, so it must not be sent"
      assert_equal [ "get_page" ], request[:tools].pluck(:function).pluck(:name)
    end
  end

  test "DeepSeek keeps the agent's own tools alongside the servers'" do
    provider = deepseek(
      mcps:  MCP_SERVERS,
      tools: [ { name: "local_tool", description: "Local", parameters: { type: "object", properties: {} } } ]
    )

    with_bridge do
      request = provider.prompt_request_type.cast(provider.send(:prompt_context).except(:trace_id)).serialize

      assert_equal %w[local_tool get_page], request[:tools].pluck(:function).pluck(:name)
    end
  end

  test "Anthropic still sends mcp_servers" do
    provider = anthropic(mcps: MCP_SERVERS)

    request = provider.prompt_request_type.cast(provider.send(:prompt_context).except(:trace_id)).serialize

    assert_equal MCP_SERVERS, provider.send(:prompt_context)[:mcps]
    assert_equal 1, request[:mcp_servers].size
  end

  test "a provider with no mcps: is untouched" do
    provider = deepseek(mcps: nil)

    assert_nil provider.send(:mcp_bridge)
    assert_equal provider.context, provider.send(:prompt_context)
  end

  # A preview must not do I/O — discovering MCP tools means connecting to the
  # servers — so it drops the declaration and shows only declared tools.
  test "a preview drops mcps: without connecting to a server" do
    provider = deepseek(mcps: MCP_SERVERS)

    ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { fail "the bridge must not be built for a preview" }) do
      context = provider.send(:preview_context)

      assert_not context.key?(:mcps)
      assert_nil context[:tools]
    end
  end

  test "a preview of a provider that runs MCP itself is unchanged" do
    provider = anthropic(mcps: MCP_SERVERS)

    ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { fail "the bridge must not be used for Anthropic" }) do
      assert_equal MCP_SERVERS, provider.send(:preview_context)[:mcps]
    end
  end

  private

  def deepseek(**kwargs)
    ActiveAgent::Providers::DeepSeekProvider.new(
      { service: "DeepSeek", api_key: "test", messages: MESSAGES }.merge(kwargs)
    )
  end

  def anthropic(**kwargs)
    ActiveAgent::Providers::AnthropicProvider.new(
      { service: "Anthropic", api_key: "test", messages: MESSAGES }.merge(kwargs)
    )
  end

  # Replaces the bridge the provider builds with one whose `connect` is stubbed,
  # so no transport is opened.
  def with_bridge(&)
    client = FakeClient.new

    bridge = ActiveAgent::Providers::MCPBridge.new(MCP_SERVERS)
    bridge.define_singleton_method(:connect) do |declaration|
      ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
    end

    # A lambda, not the bridge itself: Minitest's `stub` calls a value that
    # responds to `call`, and the bridge has a public `call` method of its own.
    ActiveAgent::Providers::MCPBridge.stub(:new, ->(*) { bridge }, &)
  end
end
