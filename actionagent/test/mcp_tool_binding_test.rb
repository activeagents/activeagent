# frozen_string_literal: true

require "test_helper"

class MCPToolBindingTest < ActiveSupport::TestCase
  AgentConfig = Struct.new(:mcp_servers)
  FakeClient = Struct.new(:tools, :list_calls, :failure) do
    def list_tools
      self.list_calls += 1
      raise failure if failure

      tools
    end
  end

  setup do
    @previous_catalog = ActionAgent.mcp_catalog
    ActionAgent.mcp_catalog = [
      {
        key: "warehouse", name: "Warehouse", transport: "http",
        url: "https://warehouse.example/mcp", tool_hints: [ "lookup" ]
      }
    ]
    @schema = {
      "type" => "object",
      "properties" => { "sku" => { "type" => "string" } },
      "required" => [ "sku" ], "additionalProperties" => false
    }
  end

  teardown do
    ActionAgent.mcp_catalog = @previous_catalog
  end

  test "catalog availability never enables a server or its tools" do
    ActionAgent::MCPClient.stub(:new, ->(**) { flunk "disabled servers must not be contacted" }) do
      resolver = resolver_for([])
      assert_nil resolver.resolve("lookup")
      error = assert_raises(ActionAgent::MCPToolBinding::Error) { resolver.resolve("mcp__warehouse__lookup") }
      assert_includes error.message, "not enabled"
    end
  end

  test "bare names builder hashes and legacy keyed hashes merge catalog connection settings" do
    configurations = [
      [ "warehouse" ],
      [ { "name" => "Warehouse", "key" => " WAREHOUSE " } ],
      { "warehouse" => {} }
    ]

    configurations.each do |configuration|
      client = fake_client("lookup")
      with_clients("https://warehouse.example/mcp" => client) do |connections|
        binding = resolver_for(configuration).resolve("lookup")
        assert_equal "warehouse", binding[:server]
        assert_equal @schema, binding.dig(:definition, :parameters)
        assert_equal [ { url: "https://warehouse.example/mcp", transport: "http" } ], connections
      end
    end
  end

  test "inline URL and transport override the catalog and use the live schema" do
    client = fake_client("lookup")
    configuration = [
      {
        name: "warehouse", url: "https://override.example/mcp", transport: "streamable_http",
        tools: [ { name: "lookup", inputSchema: { type: "object", properties: {} } } ]
      }
    ]

    with_clients("https://override.example/mcp" => client) do |connections|
      binding = resolver_for(configuration).resolve("lookup")
      assert_equal "Look up lookup", binding.dig(:definition, :description)
      assert_equal @schema, binding.dig(:definition, :parameters)
      assert_equal "streamable_http", connections.first[:transport]
    end
  end

  test "namespaced tools keep their offered name and strip only their server prefix on the wire" do
    client = fake_client("lookup__details")

    with_clients("https://warehouse.example/mcp" => client) do
      binding = resolver_for([ "warehouse" ]).resolve("mcp__warehouse__lookup__details")
      assert_equal "lookup__details", binding[:name]
      assert_equal "mcp__warehouse__lookup__details", binding.dig(:definition, :name)
      assert_same client, binding[:client]
    end
  end

  test "explicit namespaced tool declarations also claim their bare name" do
    configuration = [
      { key: "warehouse", tools: [ "mcp__warehouse__lookup" ] },
      { key: "unreachable", url: "https://unreachable.example/mcp" }
    ]

    with_clients("https://warehouse.example/mcp" => fake_client("lookup")) do |connections|
      assert_equal "warehouse", resolver_for(configuration).resolve("lookup")[:server]
      assert_equal 1, connections.length
    end
  end

  test "catalog hints are not exhaustive and additional bare tools are discovered live" do
    client = fake_client("reserve")

    with_clients("https://warehouse.example/mcp" => client) do
      binding = resolver_for([ "warehouse" ]).resolve("reserve")
      assert_equal "reserve", binding[:name]
      assert_equal @schema, binding.dig(:definition, :parameters)
    end
  end

  test "servers without declarations discover tools with an inline URL and default transport" do
    configuration = { "private" => { "url" => "https://private.example/mcp" } }

    with_clients("https://private.example/mcp" => fake_client("reserve")) do
      assert_equal "private", resolver_for(configuration).resolve("reserve")[:server]
    end
  end

  test "discovery and bindings reuse the same client and tool list within a run" do
    client = fake_client("lookup", "reserve")

    with_clients("https://warehouse.example/mcp" => client) do |connections|
      resolver = resolver_for([ "warehouse", "warehouse" ])
      binding = resolver.resolve("lookup")
      assert_same binding, resolver.resolve("lookup")
      assert_same client, resolver.resolve("reserve")[:client]
      assert_nil resolver.resolve("unrelated")
      assert_nil resolver.resolve("unrelated")
      assert_equal 1, client.list_calls
      assert_equal 1, connections.length
    end
  end

  test "an enabled server claim missing from tools list fails instead of allowing fallback" do
    with_clients("https://warehouse.example/mcp" => fake_client("different")) do
      error = assert_raises(ActionAgent::MCPToolBinding::Error) do
        resolver_for([ "warehouse" ]).resolve("lookup")
      end
      assert_includes error.message, "warehouse"
      assert_includes error.message, "does not offer selected tool 'lookup'"
    end
  end

  test "an unreachable claimed server produces a cached actionable failure" do
    client = FakeClient.new([], 0, ActionAgent::MCPClient::Error.new("connection refused"))

    with_clients("https://warehouse.example/mcp" => client) do
      resolver = resolver_for([ "warehouse" ])
      2.times do
        error = assert_raises(ActionAgent::MCPToolBinding::Error) { resolver.resolve("lookup") }
        assert_includes error.message, "warehouse"
        assert_includes error.message, "connection refused"
        assert_includes error.message, "URL and transport"
      end
      assert_equal 1, client.list_calls
    end
  end

  test "unclaimed HTTP discovery failures are actionable" do
    client = FakeClient.new([], 0, ActionAgent::MCPClient::Error.new("connection refused"))

    with_clients("https://warehouse.example/mcp" => client) do
      assert_raises(ActionAgent::MCPToolBinding::Error) do
        resolver_for([ "warehouse" ]).resolve("reserve")
      end
    end
  end

  test "unsupported servers are skipped for unrelated tools but fail when they claim a selected tool" do
    resolver = resolver_for([ "filesystem" ])
    assert_nil resolver.resolve("unrelated")

    error = assert_raises(ActionAgent::MCPToolBinding::Error) { resolver.resolve("read_file") }
    assert_includes error.message, "filesystem"
    assert_includes error.message, "stdio"
  end

  test "ambiguous configured bare tool claims require a namespace" do
    configuration = [
      { key: "first", tools: [ "query" ] },
      { key: "second", tool_hints: [ "query" ] }
    ]

    error = assert_raises(ActionAgent::MCPToolBinding::Error) { resolver_for(configuration).resolve("query") }
    assert_includes error.message, "first, second"
    assert_includes error.message, "mcp__SERVER__query"
  end

  test "ambiguous discovered bare tools require a namespace while explicit names select one" do
    configuration = [
      { key: "first", url: "https://first.example/mcp" },
      { key: "second", url: "https://second.example/mcp" }
    ]

    with_clients(
      "https://first.example/mcp" => fake_client("query"),
      "https://second.example/mcp" => fake_client("query")
    ) do
      resolver = resolver_for(configuration)
      assert_raises(ActionAgent::MCPToolBinding::Error) { resolver.resolve("query") }
      assert_equal "first", resolver.resolve("mcp__first__query")[:server]
    end
  end

  test "tools without live input schemas fail rather than inventing an empty schema" do
    client = FakeClient.new([ { "name" => "lookup" } ], 0)

    with_clients("https://warehouse.example/mcp" => client) do
      error = assert_raises(ActionAgent::MCPToolBinding::Error) do
        resolver_for([ "warehouse" ]).resolve("lookup")
      end
      assert_includes error.message, "inputSchema"
    end
  end

  private

  def resolver_for(configuration)
    ActionAgent::MCPToolBinding.new(AgentConfig.new(configuration))
  end

  def fake_client(*names)
    FakeClient.new(names.map { |name| { "name" => name, "description" => "Look up #{name}", "inputSchema" => @schema } }, 0)
  end

  def with_clients(clients)
    connections = []
    factory = lambda do |**options|
      connections << options
      clients.fetch(options[:url])
    end
    ActionAgent::MCPClient.stub(:new, factory) { yield connections }
  end
end
