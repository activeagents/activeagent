# frozen_string_literal: true

require "test_helper"
require "mcp"
require "active_agent/providers/mcp_bridge"

# The bridge's own behaviour: discovery, the common-format conversion, collision
# detection, call routing and result flattening. The gem's transports are not
# exercised — `connect` is stubbed with a stand-in client, because what can break
# here is the glue, not the protocol.
class MCPBridgeTest < ActiveSupport::TestCase
  # Stands in for a connected client.
  class FakeClient
    attr_reader :calls

    def initialize(tools: [], results: {})
      @tools   = tools
      @results = results
      @calls   = []
    end

    def tools = @tools

    def call_tool(name:, arguments:)
      @calls << { name:, arguments: }

      @results.fetch(name) { { "content" => [ { "type" => "text", "text" => "#{name} answered" } ] } }
    end
  end

  test "collects tools from every declared server" do
    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("one"), tool("two") ]) }
    )

    assert_equal %w[one two], bridge.tools.pluck(:name)
  end

  test "converts a server tool to the common format" do
    schema = { type: "object", properties: { url: { type: "string" } } }

    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("fetch", description: "Fetch a page", input_schema: schema) ]) }
    )

    assert_equal [ { name: "fetch", description: "Fetch a page", parameters: schema } ], bridge.tools
  end

  test "gives a tool with no schema an empty object schema" do
    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("ping", input_schema: nil) ]) }
    )

    assert_equal({ type: "object", properties: {} }, bridge.tools.first[:parameters])
  end

  test "merges the declared tools with the servers' tools" do
    declared = [ { name: "local", description: "Local", parameters: {} } ]

    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("remote") ]) }
    )

    assert_equal %w[local remote], bridge.merge_tools(declared).pluck(:name)
  end

  test "refuses two servers offering the same tool name" do
    bridge = build_bridge(
      [ { name: "alpha", url: "https://alpha.test/mcp" }, { name: "beta", url: "https://beta.test/mcp" } ],
      {
        "alpha" => FakeClient.new(tools: [ tool("search") ]),
        "beta"  => FakeClient.new(tools: [ tool("search") ])
      }
    )

    error = assert_raises(ActiveAgent::Providers::MCPBridge::DuplicateToolError) { bridge.tools }

    assert_includes error.message, %("alpha")
    assert_includes error.message, %("beta")
    assert_includes error.message, %("search")
  end

  test "refuses a declared tool that collides with a server tool" do
    declared = [ { name: "search", description: "Local", parameters: {} } ]

    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("search") ]) }
    )

    error = assert_raises(ActiveAgent::Providers::MCPBridge::DuplicateToolError) { bridge.merge_tools(declared) }

    assert_includes error.message, %("search")
  end

  test "honours allowed_tools" do
    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp", allowed_tools: [ "keep" ] },
      { "alpha" => FakeClient.new(tools: [ tool("keep"), tool("drop") ]) }
    )

    assert_equal %w[keep], bridge.tools.pluck(:name)
  end

  test "routes a call to the server that owns the tool" do
    alpha = FakeClient.new(tools: [ tool("one") ])
    beta  = FakeClient.new(tools: [ tool("two") ])

    bridge = build_bridge(
      [ { name: "alpha", url: "https://alpha.test/mcp" }, { name: "beta", url: "https://beta.test/mcp" } ],
      { "alpha" => alpha, "beta" => beta }
    )

    bridge.call("two", city: "NYC")

    assert_empty alpha.calls
    assert_equal [ { name: "two", arguments: { city: "NYC" } } ], beta.calls
  end

  test "joins the text blocks of a result" do
    client = FakeClient.new(
      tools:   [ tool("search") ],
      results: { "search" => { "content" => [ { "type" => "text", "text" => "first" },
                                              { "type" => "text", "text" => "second" } ] } }
    )

    bridge = build_bridge({ name: "alpha", url: "https://alpha.test/mcp" }, { "alpha" => client })

    assert_equal "first\nsecond", bridge.call("search")
  end

  test "prefers structured content when the server sends it" do
    structured = { "temperature" => 21 }

    client = FakeClient.new(
      tools:   [ tool("weather") ],
      results: { "weather" => { "content" => [ { "type" => "text", "text" => "ignored" } ],
                                "structuredContent" => structured } }
    )

    bridge = build_bridge({ name: "alpha", url: "https://alpha.test/mcp" }, { "alpha" => client })

    assert_equal structured, bridge.call("weather")
  end

  test "refuses a tool that no server provides" do
    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("one") ]) }
    )

    error = assert_raises(ArgumentError) { bridge.call("nonexistent") }

    assert_includes error.message, %("nonexistent")
  end

  test "reports whether a server owns a tool" do
    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("one") ]) }
    )

    assert bridge.owns?("one")
    assert bridge.owns?(:one)
    assert_not bridge.owns?("two")
  end

  test "takes the server name from the url when none is given" do
    bridge = build_bridge(
      { url: "https://alpha.test/mcp" },
      { "https://alpha.test/mcp" => FakeClient.new(tools: [ tool("one") ]) }
    )

    assert_equal %w[one], bridge.tools.pluck(:name)
  end

  test "requires each declaration to be a Hash" do
    error = assert_raises(ArgumentError) { ActiveAgent::Providers::MCPBridge.new([ "https://alpha.test/mcp" ]) }

    assert_includes error.message, "must be a Hash"
  end

  test "reports an empty bridge" do
    assert_predicate ActiveAgent::Providers::MCPBridge.new(nil), :empty?
    assert_predicate ActiveAgent::Providers::MCPBridge.new([]), :empty?
    assert_not_predicate ActiveAgent::Providers::MCPBridge.new([ { url: "https://alpha.test/mcp" } ]), :empty?
  end

  test "builds an HTTP transport for a url" do
    bridge = ActiveAgent::Providers::MCPBridge.new([ { url: "https://alpha.test/mcp" } ])

    assert_instance_of MCP::Client::HTTP, bridge.send(:transport_for, { url: "https://alpha.test/mcp" })
  end

  test "builds a stdio transport for a command" do
    bridge = ActiveAgent::Providers::MCPBridge.new([ { command: "mcp-server" } ])

    assert_instance_of MCP::Client::Stdio,
                       bridge.send(:transport_for, { command: "mcp-server", args: [ "--verbose" ] })
  end

  test "requires a url or a command to connect to" do
    bridge = ActiveAgent::Providers::MCPBridge.new([ { name: "alpha" } ])

    error = assert_raises(ArgumentError) { bridge.send(:transport_for, { name: "alpha" }) }

    assert_includes error.message, "`url:` or a `command:`"
  end

  test "sends an authorization token as a bearer header" do
    bridge = ActiveAgent::Providers::MCPBridge.new([ { url: "https://alpha.test/mcp" } ])

    headers = bridge.send(:headers_for, { authorization: "secret" })

    assert_equal({ "Authorization" => "Bearer secret" }, headers)
  end

  private

  def tool(name, description: "#{name} tool", input_schema: { type: "object", properties: {} })
    MCP::Client::Tool.new(name:, description:, input_schema:)
  end

  # Builds a bridge whose `connect` returns a stand-in client, so no transport is
  # opened and no server is needed.
  def build_bridge(declarations, clients_by_name)
    bridge = ActiveAgent::Providers::MCPBridge.new(declarations)

    bridge.define_singleton_method(:connect) do |declaration|
      client = clients_by_name.fetch(declaration[:name])

      ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
    end

    bridge
  end
end
