# frozen_string_literal: true

require "test_helper"

# Routing a tool call to the MCP server that serves it (#419): an agent names
# its servers, the host registers where they live, and the dashboard calls
# them instead of falling through to its own toolbox.
class MCPToolDispatcherTest < ActiveSupport::TestCase
  setup do
    @catalog = ActionAgent.mcp_catalog
    ActionAgent.mcp_catalog = [
      { key: "records", name: "Records", description: "Record lookups.",
        transport: "http", url: "https://host.example/mcp/records",
        tool_hints: %w[count_records find_records] },
      { key: "local", name: "Local", description: "A stdio server.",
        transport: "stdio", command: "npx local-mcp", tool_hints: %w[read_file] }
    ]
  end

  teardown { ActionAgent.mcp_catalog = @catalog }

  def agent_with(servers, tools: [])
    ActionAgent::Agent.new(name: "Probe", status: :draft, provider: "openai",
                           model: "gpt-4o-mini", mcp_servers: servers, tools: tools)
  end

  test "a tool an agent's http server serves is dispatchable" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(%w[records]))

    assert dispatcher.dispatchable?("count_records")
  end

  test "a tool from a server the agent does not declare is left to the toolbox" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with([]))

    assert_not dispatcher.dispatchable?("count_records")
    assert_nil dispatcher.call("count_records")
  end

  test "a stdio server is not dispatchable — the dashboard has no address to call" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(%w[local]))

    assert_not dispatcher.dispatchable?("read_file")
  end

  # VCR hooks into webmock and refuses any request without a cassette, so these
  # tests substitute the client rather than stub HTTP. The dispatcher memoizes
  # its clients per server key, so seeding that hash injects the double.

  # Stands in for MCPClient, answering the two calls the dispatcher makes.
  class StubClient
    def initialize(tools: [], raises: nil)
      @tools = tools
      @raises = raises
    end

    def list_tools
      raise ActionAgent::MCPClient::Error, @raises if @raises

      @tools
    end

    def call_tool(name, _arguments)
      raise ActionAgent::MCPClient::Error, @raises if @raises

      { "content" => [ { "type" => "text", "text" => "called #{name}" } ] }
    end
  end

  def dispatcher_with_client(client, servers: %w[records])
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(servers))
    dispatcher.instance_variable_get(:@clients)["records"] = client
    dispatcher
  end

  test "an unreachable server returns a scoreable error rather than raising" do
    dispatcher = dispatcher_with_client(StubClient.new(raises: "boom"))

    result = dispatcher.call("count_records", { "model" => "Physician" })

    assert_match(/count_records failed: boom/, result[:error])
  end

  test "a server's own tools/list becomes the schemas the model is offered" do
    tools = [ { name: "count_records", description: "Counts rows.", parameters: { type: "object" } } ]
    dispatcher = dispatcher_with_client(StubClient.new(tools: tools))

    assert_equal %w[count_records], dispatcher.tool_definitions.map { |tool| tool[:name] }
  end

  test "a server whose tools/list fails contributes no schemas" do
    dispatcher = dispatcher_with_client(StubClient.new(raises: "unreachable"))

    assert_empty dispatcher.tool_definitions
  end

  # A stateless server answers the initialize handshake with no Mcp-Session-Id,
  # and its notification body is a bare `null` — which JSON.parse returns as nil
  # rather than a hash.
  test "a bare null notification body parses as an empty hash" do
    client = ActionAgent::MCPClient.new(url: "https://host.example/mcp/records")
    response = Struct.new(:body) do
      def [](_header) = "application/json"
    end.new("null")

    assert_equal({}, client.send(:parse_body, response))
  end

  test "an https endpoint is requested over TLS, not plaintext on port 443" do
    client = ActionAgent::MCPClient.new(url: "https://host.example/mcp/records")

    assert_equal "https", client.instance_variable_get(:@uri).scheme
    assert_equal 443, client.instance_variable_get(:@uri).port
  end

  test "an observed agent with a reachable server may execute" do
    agent = agent_with(%w[records])
    agent.status = :observed

    assert_nothing_raised { agent.ensure_executable! }
  end

  test "an observed agent with nothing to call is still refused" do
    agent = agent_with([])
    agent.status = :observed

    error = assert_raises(ActionAgent::Agent::ObservedAgentError) { agent.ensure_executable! }
    assert_match(/no reachable MCP server/, error.message)
  end
end
