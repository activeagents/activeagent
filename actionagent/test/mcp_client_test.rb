# frozen_string_literal: true

require "test_helper"

class MCPClientTest < ActiveSupport::TestCase
  URL = "https://127.0.0.1:8931/mcp"
  SCHEMA = {
    "type" => "object",
    "properties" => { "query" => { "type" => "string" } },
    "required" => [ "query" ], "additionalProperties" => false
  }.freeze
  TOOL = { "name" => "search", "description" => "Search records", "inputSchema" => SCHEMA }.freeze

  teardown do
    ActionAgent::PlaywrightMCPClient.reset!
  end

  test "initializes over HTTPS once and forwards negotiated headers on discovery and calls" do
    initialization = stub_initialization(session: "test-session", version: "2025-03-26")
    listing = stub_rpc("tools/list", result: { tools: [ TOOL ] })
      .with(headers: { "Mcp-Session-Id" => "test-session", "MCP-Protocol-Version" => "2025-03-26" })
    calling = stub_rpc("tools/call", result: { content: [ { type: "text", text: "found" } ] })
      .with(headers: { "Mcp-Session-Id" => "test-session", "MCP-Protocol-Version" => "2025-03-26" }) { |req|
        JSON.parse(req.body)["params"] == { "name" => "search", "arguments" => { "query" => "hello" } }
      }

    client = ActionAgent::MCPClient.new(url: URL)
    assert_equal [ TOOL ], client.list_tools
    assert_equal [ TOOL ], client.list_tools
    assert_equal({ text: "found", is_error: false }, client.call_tool("search", query: "hello"))
    assert_requested initialization, times: 1
    assert_requested listing, times: 2
    assert_requested calling, times: 1
    assert_requested :post, URL, times: 1 do |req|
      payload = JSON.parse(req.body)
      payload["method"] == "initialize" && !req.headers.key?("Mcp-Session-Id") &&
        payload.dig("params", "protocolVersion") == ActionAgent::MCPClient::PROTOCOL_VERSION &&
        payload.dig("params", "capabilities") == {}
    end
  end

  test "stateless servers need no session id and are initialized only once" do
    initialization = stub_initialization
    stub_rpc("tools/list", result: { tools: [] })
    stub_rpc("tools/call", result: { content: [] })

    client = ActionAgent::MCPClient.new(url: URL, transport: nil)
    assert_empty client.list_tools
    assert_equal({ text: "", is_error: false }, client.call_tool("noop"))
    assert_requested initialization, times: 1
    assert_requested :post, URL, times: 4 do |req|
      !req.headers.key?("Mcp-Session-Id")
    end
  end

  test "discovery follows pagination and retains each input schema" do
    stub_initialization
    listing = stub_request(:post, URL).with { |req| JSON.parse(req.body)["method"] == "tools/list" }
      .to_return do |req|
        payload = JSON.parse(req.body)
        result = if payload["params"].empty?
          { tools: [ TOOL ], nextCursor: "second" }
        else
          assert_equal({ "cursor" => "second" }, payload["params"])
          { tools: [ TOOL.merge("name" => "lookup") ] }
        end
        rpc_response(payload["id"], result)
      end

    tools = ActionAgent::MCPClient.new(url: URL).list_tools
    assert_equal [ "search", "lookup" ], tools.map { |tool| tool["name"] }
    assert_equal [ SCHEMA, SCHEMA ], tools.map { |tool| tool["inputSchema"] }
    assert_requested listing, times: 2
  end

  test "a repeated pagination cursor fails rather than looping" do
    stub_initialization
    listing = stub_rpc("tools/list", result: { tools: [], nextCursor: "same" })

    error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL).list_tools }
    assert_match(/repeated cursor/, error.message)
    assert_requested listing, times: 2
  end

  test "SSE responses support multiline data and ignore notifications and unrelated ids" do
    stub_initialization
    stub_request(:post, URL).with { |req| JSON.parse(req.body)["method"] == "tools/list" }
      .to_return do |req|
        payload = JSON.parse(req.body)
        message = { jsonrpc: "2.0", id: payload["id"], result: { tools: [ TOOL ] } }
        data = JSON.pretty_generate(message).lines.map { |line| "data: #{line.chomp}\r\n" }.join
        {
          status: 200, headers: { "Content-Type" => "text/event-stream" },
          body: ": keepalive\r\n\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\n" \
            "data: {\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{}}\r\n\r\nevent: message\r\n#{data}\r\n"
        }
      end

    assert_equal [ TOOL ], ActionAgent::MCPClient.new(url: URL).list_tools
  end

  test "tool failures remain result values and structured output is preserved" do
    stub_initialization
    stub_rpc("tools/call", result: {
      content: [ { type: "text", text: "first" }, { type: "image", data: "image" }, { type: "text", text: "second" } ],
      isError: true, structuredContent: { reason: "missing record" }
    })

    result = ActionAgent::MCPClient.new(url: URL).call_tool("search", query: "missing")
    assert_equal "first\nsecond", result[:text]
    assert result[:is_error]
    assert_equal({ "reason" => "missing record" }, result[:structured_content])
  end

  test "structured-only tool results provide text for existing tool consumers" do
    stub_initialization
    stub_rpc("tools/call", result: { structuredContent: { count: 3 } })

    result = ActionAgent::MCPClient.new(url: URL).call_tool("count")
    assert_equal({ "count" => 3 }, JSON.parse(result[:text]))
    assert_equal({ "count" => 3 }, result[:structured_content])
  end

  test "JSON-RPC failures raise a client error" do
    stub_initialization
    stub_request(:post, URL).with { |req| JSON.parse(req.body)["method"] == "tools/list" }
      .to_return do |req|
        {
          status: 200, headers: { "Content-Type" => "application/json" },
          body: JSON.generate(jsonrpc: "2.0", id: JSON.parse(req.body)["id"], error: { code: -32601, message: "Tools unavailable" })
        }
      end

    error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL).list_tools }
    assert_match(/-32601.*Tools unavailable/, error.message)
  end

  test "HTTP failures raise a client error without exposing response contents" do
    stub_initialization
    stub_rpc("tools/list", status: 403, result: { secret: "private error detail" })

    error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL).list_tools }
    assert_equal "MCP server returned HTTP 403", error.message
  end

  test "expired sessions are initialized again and the rejected request is retried once" do
    initialization = stub_initialization(session: "test-session")
    listing = stub_request(:post, URL).with { |req| JSON.parse(req.body)["method"] == "tools/list" }
      .to_return(status: 404).then.to_return { |req| rpc_response(JSON.parse(req.body)["id"], { tools: [ TOOL ] }) }

    assert_equal [ TOOL ], ActionAgent::MCPClient.new(url: URL).list_tools
    assert_requested initialization, times: 2
    assert_requested listing, times: 2
  end

  test "a session that keeps expiring stops retrying" do
    initialization = stub_initialization(session: "test-session")
    listing = stub_rpc("tools/list", status: 404)

    assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL).list_tools }
    assert_requested initialization, times: 2
    assert_requested listing, times: 2
  end

  test "connection timeouts do not retry potentially executed tool calls" do
    stub_initialization
    calling = stub_request(:post, URL).with { |req| JSON.parse(req.body)["method"] == "tools/call" }.to_timeout

    error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL).call_tool("write") }
    assert_match(/connection failed/, error.message)
    assert_requested calling, times: 1
  end

  test "invalid JSON and unmatched response ids fail clearly" do
    stub_initialization
    listing = stub_request(:post, URL).with { |req| JSON.parse(req.body)["method"] == "tools/list" }
    listing.to_return(body: "not json", headers: { "Content-Type" => "application/json" })
    error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL).list_tools }
    assert_match(/invalid JSON/, error.message)

    listing.to_return(rpc_response(999, { tools: [] }))
    error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL).list_tools }
    assert_match(/did not return a response/, error.message)
  end

  test "malformed tool lists fail instead of silently hiding tools" do
    stub_initialization
    stub_rpc("tools/list", result: { tools: { search: {} } })

    error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL).list_tools }
    assert_match(/tools array/, error.message)
  end

  test "unsupported protocol versions stop before announcing initialization" do
    stub_rpc("initialize", result: { protocolVersion: "2099-01-01" })

    error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL).list_tools }
    assert_match(/Unsupported MCP protocol version/, error.message)
    assert_not_requested :post, URL do |req|
      JSON.parse(req.body)["method"] == "notifications/initialized"
    end
  end

  test "unsupported transports and invalid endpoints fail before making requests" do
    [ "stdio", "sse" ].each do |transport|
      error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: URL, transport: transport) }
      assert_match(/Unsupported MCP transport/, error.message)
    end
    [ "/mcp", "file:///tmp/mcp", "not a URL" ].each do |url|
      error = assert_raises(ActionAgent::MCPClient::Error) { ActionAgent::MCPClient.new(url: url) }
      assert_match(/absolute HTTP or HTTPS/, error.message)
    end
    assert_instance_of ActionAgent::MCPClient, ActionAgent::MCPClient.new(url: URL, transport: "streamable-http")
    assert_instance_of ActionAgent::MCPClient, ActionAgent::MCPClient.new(url: URL, transport: "streamable_http")
  end

  test "Playwright client keeps the singleton and tool-result interface" do
    original = ActionAgent::PlaywrightMCPClient.instance
    assert_kind_of ActionAgent::MCPClient, original
    assert_same original, ActionAgent::PlaywrightMCPClient.instance
    ActionAgent::PlaywrightMCPClient.reset!
    refute_same original, ActionAgent::PlaywrightMCPClient.instance

    stub_initialization(session: "browser-session")
    stub_rpc("tools/call", result: { content: [ { type: "text", text: "snapshot" } ] })
    result = ActionAgent::PlaywrightMCPClient.new(url: URL).call_tool("browser_snapshot")
    assert_equal({ text: "snapshot", is_error: false }, result)
  end

  private

  def stub_initialization(session: nil, version: ActionAgent::MCPClient::PROTOCOL_VERSION)
    headers = session ? { "Mcp-Session-Id" => session } : {}
    initialization = stub_rpc("initialize", result: {
      protocolVersion: version, capabilities: { tools: {} }, serverInfo: { name: "test", version: "1.0" }
    }, headers: headers)
    notification = stub_rpc("notifications/initialized", status: 202)
    notification.with(headers: { "MCP-Protocol-Version" => version }.merge(headers))
    initialization
  end

  def stub_rpc(method, result: nil, status: 200, headers: {})
    stub_request(:post, URL)
      .with(body: hash_including("method" => method),
        headers: { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" })
      .to_return do |req|
        rpc_response(JSON.parse(req.body)["id"], result).merge(status: status,
          headers: { "Content-Type" => "application/json" }.merge(headers))
      end
  end

  def rpc_response(id, result)
    {
      status: 200, headers: { "Content-Type" => "application/json" },
      body: id ? JSON.generate(jsonrpc: "2.0", id: id, result: result) : ""
    }
  end
end
