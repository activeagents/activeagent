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

  test "an unreachable server returns a scoreable error rather than raising" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(%w[records]))
    ActionAgent::MCPClient.any_instance.stubs(:call_tool)
                          .raises(ActionAgent::MCPClient::Error, "boom")

    result = dispatcher.call("count_records", { "model" => "Physician" })

    assert_match(/count_records failed: boom/, result[:error])
  end

  test "a server's own tools/list becomes the schemas the model is offered" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(%w[records]))
    ActionAgent::MCPClient.any_instance.stubs(:list_tools).returns(
      [ { name: "count_records", description: "Counts rows.", parameters: { type: "object" } } ]
    )

    assert_equal %w[count_records], dispatcher.tool_definitions.map { |tool| tool[:name] }
  end

  test "a server whose tools/list fails contributes no schemas" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(%w[records]))
    ActionAgent::MCPClient.any_instance.stubs(:list_tools)
                          .raises(ActionAgent::MCPClient::Error, "unreachable")

    assert_empty dispatcher.tool_definitions
  end

  test "a stateless server, which returns no session id, still completes the handshake" do
    client = ActionAgent::MCPClient.new(url: "https://host.example/mcp", label: "Stateless")
    client.stubs(:post_raw).returns([ { "result" => {} }, {} ])
    client.stubs(:post).returns({ "result" => { "tools" => [] } })

    assert_empty client.list_tools
  end

  test "a notification answered with a bare null body is not an error" do
    response = mock
    response.stubs(:body).returns("null")
    response.stubs(:[]).with("Content-Type").returns("application/json")
    client = ActionAgent::MCPClient.new(url: "https://host.example/mcp")

    assert_equal({}, client.send(:parse_body, response))
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
