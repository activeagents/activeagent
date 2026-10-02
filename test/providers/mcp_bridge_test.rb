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
  #
  # `call_tool` returns the JSON-RPC envelope, which is what the real client
  # does — an earlier version of this fake returned the tool result directly and
  # hid a bug that only a live server exposed.
  class FakeClient
    attr_reader :calls, :transport

    def initialize(tools: [], results: {}, transport: nil)
      @tools     = tools
      @results   = results
      @transport = transport
      @calls     = []
    end

    def tools = @tools

    def call_tool(name:, arguments:)
      @calls << { name:, arguments: }

      result = @results.fetch(name) { { "content" => [ { "type" => "text", "text" => "#{name} answered" } ] } }

      { "jsonrpc" => "2.0", "id" => 1, "result" => result }
    end
  end

  # Stands in for a transport, which is where `close` lives: the client wrapper
  # exposes none of its own, so a bridge that closed the client rather than its
  # transport would leak every server it ever connected to.
  class FakeTransport
    attr_reader :closes

    def initialize(raise_on_close: false)
      @closes         = 0
      @raise_on_close = raise_on_close
    end

    def close
      @closes += 1

      raise "the server refused to shut down" if @raise_on_close
    end
  end

  # The cache is process-global, so an entry left by one test is visible to the
  # next — and two servers that differ only in `name:` share a fingerprint, since
  # the name does not change what a server offers.
  setup    { ActiveAgent::Providers::MCPToolCache.reset! }
  teardown { ActiveAgent::Providers::MCPToolCache.reset! }

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

  # The real client raises on an error envelope rather than returning it.
  test "returns a server's JSON-RPC error to the model instead of failing the generation" do
    client = FakeClient.new(tools: [ tool("search") ])
    client.define_singleton_method(:call_tool) do |name:, arguments:|
      raise MCP::Client::ServerError.new("Invalid params: q must be a string", code: -32602)
    end
    bridge = build_bridge({ name: "alpha", url: "https://alpha.test/mcp" }, { "alpha" => client })

    assert_equal "Invalid params: q must be a string", bridge.call("search", q: 1)
  end

  test "unwraps the JSON-RPC envelope the client returns" do
    client = FakeClient.new(tools: [ tool("one") ])

    bridge = build_bridge({ name: "alpha", url: "https://alpha.test/mcp" }, { "alpha" => client })

    assert_equal "one answered", bridge.call("one")
  end

  test "returns a JSON-RPC error to the model instead of raising" do
    client = FakeClient.new(tools: [ tool("one") ])
    client.define_singleton_method(:call_tool) do |name:, arguments:|
      { "jsonrpc" => "2.0", "id" => 1, "error" => { "code" => -32_602, "message" => "Unknown tool" } }
    end

    bridge = build_bridge({ name: "alpha", url: "https://alpha.test/mcp" }, { "alpha" => client })

    assert_equal "Unknown tool", bridge.call("one")
  end

  # A tool is free to use `result` as a field name, so only the envelope's own
  # marker justifies unwrapping.
  test "does not unwrap a result that merely has a result key" do
    client = FakeClient.new(
      tools:   [ tool("one") ],
      results: { "one" => { "result" => "kept", "content" => [ { "type" => "text", "text" => "block" } ] } }
    )

    bridge = build_bridge({ name: "alpha", url: "https://alpha.test/mcp" }, { "alpha" => client })

    assert_equal "block", bridge.call("one")
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

  test "takes the server name from the url's host when none is given" do
    bridge = build_bridge(
      { url: "https://alpha.test/mcp" },
      { "alpha.test" => FakeClient.new(tools: [ tool("one") ]) }
    )

    assert_equal %w[one], bridge.tools.pluck(:name)
  end

  # An MCP endpoint usually carries its key in the path, and this name reaches
  # error messages — which reach log aggregators and error trackers.
  test "keeps a url's path, which may carry the key, out of the derived name" do
    bridge = ActiveAgent::Providers::MCPBridge.new(nil)
    name   = bridge.send(:normalize, { url: "https://mcp.example.com/sk-live-secret/v2/mcp" })[:name]

    assert_equal "mcp.example.com", name
    assert_not_includes name, "sk-live-secret"
  end

  test "names a command declaration by the executable it runs" do
    bridge = ActiveAgent::Providers::MCPBridge.new(nil)

    assert_equal "command: mcp-server", bridge.send(:normalize, { command: "/opt/bin/mcp-server" })[:name]
  end

  test "falls back to a placeholder when it cannot derive a name" do
    bridge = ActiveAgent::Providers::MCPBridge.new(nil)

    assert_equal "unnamed server", bridge.send(:normalize, { url: "not a url" })[:name]
  end

  test "does not leak a key from a nameless url into a collision error" do
    bridge = build_bridge(
      [ { url: "https://alpha.test/sk-live-secret/mcp" }, { url: "https://alpha.test/sk-other-secret/mcp" } ],
      { "alpha.test" => FakeClient.new(tools: [ tool("one") ]) }
    )

    error = assert_raises(ActiveAgent::Providers::MCPBridge::DuplicateToolError) { bridge.tools }

    assert_not_includes error.message, "sk-live-secret"
    assert_not_includes error.message, "sk-other-secret"
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

  # Spawning a process requires String environment keys and values; a declaration's keys are symbolized on
  # the way in, and a value may be a number.
  test "hands a stdio server its environment with String keys and values" do
    bridge    = ActiveAgent::Providers::MCPBridge.new(nil)
    transport = bridge.send(:transport_for, { command: "mcp-server", env: { TOKEN: "secret", PORT: 8080 } })

    assert_equal({ "TOKEN" => "secret", "PORT" => "8080" }, transport.instance_variable_get(:@env))
  end

  test "requires a url or a command to connect to, without repeating the declaration's values" do
    bridge = ActiveAgent::Providers::MCPBridge.new([ { name: "alpha" } ])

    error = assert_raises(ArgumentError) do
      bridge.send(:transport_for, { name: "alpha", authorization: "sk-SECRET-123", env: { "TOKEN" => "hunter2" } })
    end

    assert_includes error.message, "`url:` or a `command:`"
    assert_includes error.message, ":authorization"
    assert_not_includes error.message, "sk-SECRET-123"
    assert_not_includes error.message, "hunter2"
  end

  # The stdio transport's own read timeout restarts with every frame it reads,
  # so the bridge bounds a server's answer itself and leaves the transport
  # without one, which keeps the gem's short bound on the `server/discover`
  # probe. The gem exposes no reader for this, so reaching in is the only way to
  # assert it. MCPBridgeReadTimeoutTest covers the bound against a real server.
  test "leaves the stdio transport's own read timeout unset" do
    bridge    = ActiveAgent::Providers::MCPBridge.new(nil)
    transport = bridge.send(:transport_for, { command: "mcp-server", read_timeout: 2 })

    assert_nil transport.instance_variable_get(:@read_timeout)
  end

  # The gem builds its Faraday connection on first use and exposes no reader
  # for it, so reaching in is the only way to see what a request is sent with.
  # Building the connection opens none.
  test "bounds a url server's reads by its declared read timeout" do
    bridge    = ActiveAgent::Providers::MCPBridge.new(nil)
    transport = bridge.send(:transport_for, { url: "https://alpha.test/mcp", read_timeout: 7 })

    assert_equal 7, transport.send(:client).options.read_timeout
  end

  test "bounds a url server's reads by the default read timeout when none is declared" do
    bridge    = ActiveAgent::Providers::MCPBridge.new(nil)
    transport = bridge.send(:transport_for, { url: "https://alpha.test/mcp" })

    assert_equal ActiveAgent::Providers::MCPBridge::DEFAULT_READ_TIMEOUT, transport.send(:client).options.read_timeout
  end

  test "honours a declared read timeout" do
    bridge = ActiveAgent::Providers::MCPBridge.new(nil)

    assert_equal 2, bridge.send(:read_timeout_for, { read_timeout: 2 })
  end

  test "refuses a read timeout that would lift the bound entirely" do
    bridge = ActiveAgent::Providers::MCPBridge.new(nil)

    error = assert_raises(ArgumentError) { bridge.send(:read_timeout_for, { read_timeout: 0 }) }

    assert_includes error.message, "positive number"
  end

  test "refuses a read timeout that is not a positive, finite number, whichever the transport" do
    bridge = ActiveAgent::Providers::MCPBridge.new(nil)

    [ { url: "https://alpha.test/mcp" }, { command: "mcp-server" } ].product([ "abc", 0, -1, Float::INFINITY ]).each do |server, timeout|
      error = assert_raises(ArgumentError, "a #{server.keys.first}: server with read_timeout: #{timeout.inspect}") do
        bridge.send(:transport_for, server.merge(read_timeout: timeout))
      end

      assert_includes error.message, "positive number"
    end
  end

  test "gives each schema-less tool its own schema object" do
    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("one", input_schema: nil), tool("two", input_schema: nil) ]) }
    )

    first, second = bridge.tools.map { |converted| converted[:parameters] }

    assert_equal({ type: "object", properties: {} }, first)
    assert_not_same first, second, "one shared schema would let a transform corrupt every other tool"
  end

  test "keeps the shared empty schema frozen so it cannot be corrupted" do
    assert_predicate ActiveAgent::Providers::MCPBridge::EMPTY_SCHEMA, :frozen?
  end

  test "closes every transport it opened" do
    alpha = FakeTransport.new
    beta  = FakeTransport.new

    bridge = build_bridge(
      [ { name: "alpha", url: "https://alpha.test/mcp" }, { name: "beta", url: "https://beta.test/mcp" } ],
      { "alpha" => FakeClient.new(tools: [ tool("one") ], transport: alpha),
        "beta"  => FakeClient.new(tools: [ tool("two") ], transport: beta) }
    )

    bridge.tools
    bridge.close

    assert_equal 1, alpha.closes
    assert_equal 1, beta.closes
  end

  test "closes a server it reached even when a later one fails to connect" do
    alpha = FakeTransport.new

    bridge = build_bridge(
      [ { name: "alpha", url: "https://alpha.test/mcp" }, { name: "beta", url: "https://beta.test/mcp" } ],
      # `beta` is absent, so connecting to it raises part-way through discovery.
      { "alpha" => FakeClient.new(tools: [ tool("one") ], transport: alpha) }
    )

    assert_raises(KeyError) { bridge.tools }

    bridge.close

    assert_equal 1, alpha.closes, "a half-finished discovery must still reap what it opened"
  end

  test "can be closed twice without closing a transport twice" do
    alpha = FakeTransport.new

    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("one") ], transport: alpha) }
    )

    bridge.tools
    2.times { bridge.close }

    assert_equal 1, alpha.closes
  end

  test "does not raise when a server refuses to shut down" do
    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("one") ], transport: FakeTransport.new(raise_on_close: true)) }
    )

    bridge.tools

    assert_nil bridge.close, "a teardown failure must not replace the error the generation was carrying"
  end

  # A connection is what the cache buys back: a generation whose tools all come
  # from the cache and never calls one should open nothing at all.
  test "opens no connection until a tool is actually called" do
    connects = 0
    client   = FakeClient.new(tools: [ tool("one") ])

    bridge = new_bridge
    bridge.define_singleton_method(:connect) do |declaration|
      connects += 1
      ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
    end

    # Cold: discovery has to connect, because there is nothing cached yet.
    assert_equal %w[one], bridge.tools.pluck(:name)
    assert_equal 1, connects

    warm = new_bridge
    warm.define_singleton_method(:connect) do |declaration|
      connects += 1
      ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
    end

    assert_equal %w[one], warm.tools.pluck(:name)
    assert_equal 1, connects, "a cached tool list must not need a connection"

    # The call opens one, because a connection is what runs a tool.
    assert_equal "one answered", warm.call("one")
    assert_equal 2, connects
  end

  test "shares a cached list between declarations that differ only in name" do
    connects = 0
    client   = FakeClient.new(tools: [ tool("one") ])

    build = lambda do |name|
      bridge = ActiveAgent::Providers::MCPBridge.new([ { name:, url: "https://alpha.test/mcp" } ])
      bridge.define_singleton_method(:connect) do |declaration|
        connects += 1
        ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
      end
      bridge
    end

    assert_equal %w[one], build.call("alpha").tools.pluck(:name)
    assert_equal %w[one], build.call("renamed").tools.pluck(:name)

    assert_equal 1, connects, "the display name does not change what a server offers"
  end

  test "does not share tool lists across credentials for the same endpoint" do
    connects = 0
    clients = {
      "first-secret" => FakeClient.new(tools: [ tool("first_account_tool") ]),
      "second-secret" => FakeClient.new(tools: [ tool("second_account_tool") ])
    }

    build = lambda do |token|
      declaration = { name: "firecrawl", url: "https://alpha.test/mcp", authorization: token }
      bridge = ActiveAgent::Providers::MCPBridge.new([ declaration ])
      bridge.define_singleton_method(:connect) do |current|
        connects += 1
        client = clients.fetch(current[:authorization])
        ActiveAgent::Providers::MCPBridge::Server.new(name: current[:name], declaration: current, client:)
      end
      bridge
    end

    assert_equal %w[first_account_tool], build.call("first-secret").tools.pluck(:name)
    assert_equal %w[second_account_tool], build.call("second-secret").tools.pluck(:name)
    assert_equal 2, connects
    refute_includes ActiveAgent::Providers::MCPBridge.new(nil).send(:fingerprint_for,
                                                                    { url: "https://alpha.test/mcp", authorization: "first-secret" }),
                    "first-secret", "the cache key must not retain the raw credential"
  end

  test "mcp_cache false bypasses the shared cache for this generation only" do
    cached_calls = 0
    cached_client = FakeClient.new(tools: [ tool("cached_tool") ])
    declaration = { name: "alpha", url: "https://alpha.test/mcp" }

    warm = ActiveAgent::Providers::MCPBridge.new([ declaration ])
    warm.define_singleton_method(:connect) do |current|
      cached_calls += 1
      ActiveAgent::Providers::MCPBridge::Server.new(name: current[:name], declaration: current, client: cached_client)
    end
    assert_equal %w[cached_tool], warm.tools.pluck(:name)

    fresh_calls = 0
    fresh_client = FakeClient.new(tools: [ tool("fresh_tool") ])
    fresh = ActiveAgent::Providers::MCPBridge.new([ declaration ], cache: false)
    fresh.define_singleton_method(:connect) do |current|
      fresh_calls += 1
      ActiveAgent::Providers::MCPBridge::Server.new(name: current[:name], declaration: current, client: fresh_client)
    end
    assert_equal %w[fresh_tool], fresh.tools.pluck(:name)

    still_cached = ActiveAgent::Providers::MCPBridge.new([ declaration ])
    still_cached.define_singleton_method(:connect) do |current|
      cached_calls += 1
      ActiveAgent::Providers::MCPBridge::Server.new(name: current[:name], declaration: current, client: cached_client)
    end
    assert_equal %w[cached_tool], still_cached.tools.pluck(:name)

    assert_equal 1, cached_calls, "the disabled generation must not overwrite the shared entry"
    assert_equal 1, fresh_calls
  end

  test "refresh! drops the cached list so the next use asks again" do
    connects = 0
    client   = FakeClient.new(tools: [ tool("one") ])

    bridge = new_bridge
    bridge.define_singleton_method(:connect) do |declaration|
      connects += 1
      ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
    end

    bridge.tools
    assert_equal 1, connects

    bridge.refresh!
    bridge.tools

    assert_equal 2, connects, "refresh! must invalidate, not just reconnect"
  end

  test "connects for every generation when the cache is disabled" do
    ActiveAgent::Providers::MCPToolCache.configure(enabled: false)

    connects = 0
    client   = FakeClient.new(tools: [ tool("one") ])

    2.times do
      bridge = new_bridge
      bridge.define_singleton_method(:connect) do |declaration|
        connects += 1
        ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)
      end
      bridge.tools
    end

    assert_equal 2, connects
  end

  test "rediscovers after being closed rather than handing back stale clients" do
    bridge = build_bridge(
      { name: "alpha", url: "https://alpha.test/mcp" },
      { "alpha" => FakeClient.new(tools: [ tool("one") ]) }
    )

    assert_equal %w[one], bridge.tools.pluck(:name)

    bridge.close

    assert_equal %w[one], bridge.tools.pluck(:name)
    assert bridge.owns?("one"), "the rediscovers must restore ownership, not just the tool list"
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

  # Builds a bridge over the single standard server, for a test that replaces
  # `connect` itself.
  def new_bridge
    ActiveAgent::Providers::MCPBridge.new([ { name: "alpha", url: "https://alpha.test/mcp" } ])
  end

  # Builds a bridge whose `connect` returns a stand-in client, so no transport is
  # opened and no server is needed.
  #
  # The stub mirrors the real `connect` in recording the server it reaches, so
  # `close` sees the same set of connections it would in production.
  def build_bridge(declarations, clients_by_name)
    bridge = ActiveAgent::Providers::MCPBridge.new(declarations)

    bridge.define_singleton_method(:connect) do |declaration|
      client = clients_by_name.fetch(declaration[:name])
      server = ActiveAgent::Providers::MCPBridge::Server.new(name: declaration[:name], declaration:, client:)

      instance_variable_get(:@servers) << server
      server
    end

    bridge
  end
end
