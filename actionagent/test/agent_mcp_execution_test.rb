# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

class AgentMCPExecutionTest < ActiveSupport::TestCase
  TelemetryTraceTest.ensure_table!
  class Client
    attr_reader :calls, :lists
    attr_accessor :result

    def initialize(names)
      @names = names
      @calls = []
      @lists = 0
      @result = { text: "Host database is healthy", is_error: false }
    end

    def list_tools
      @lists += 1
      @names.map do |name|
        { "name" => name, "description" => "Host #{name}",
          "inputSchema" => { "type" => "object", "properties" => { "service" => { "type" => "string" } },
                             "required" => [ "service" ] } }
      end
    end

    def call_tool(name, arguments)
      @calls << [ name, arguments ]
      raise result if result.is_a?(Exception)

      result
    end
  end

  setup do
    @original_catalog = ActionAgent.mcp_catalog
    ActionAgent.mcp_catalog = [ { key: "host", name: "Host", transport: "http", url: "https://host.example/mcp",
                                 tool_hints: %w[healthcheck calculate] } ]
    @agent = ActionAgent::Agent.create!(name: "Host assistant", provider: "mock", model: "mock",
      tools: [ "healthcheck" ], mcp_servers: [ "host" ])
    @run = @agent.agent_runs.create!(input_prompt: "Check database health", status: :running, trace_id: SecureRandom.hex(16))
    @service = ActionAgent::AgentExecutionService.new(@agent, @run)
  end

  teardown do
    ActionAgent.mcp_catalog = @original_catalog
  end

  test "live MCP schemas and calls use the same session and selected tool roster" do
    client = Client.new(%w[healthcheck calculate])
    ActionAgent::MCPClient.stub(:new, client) do
      schemas = @service.resolved_tool_schemas
      assert_equal [ "healthcheck" ], schemas.map { |definition| definition[:name] }
      assert_equal [ "service" ], schemas.first[:parameters]["required"]

      2.times { assert_equal client.result, @service.execute_tool("healthcheck", service: "database") }
      assert_equal 1, client.lists
      assert_equal [ [ "healthcheck", { service: "database" } ] ] * 2, client.calls
      assert_raises(ActionAgent::AgentExecutionService::ToolNotConfiguredError) do
        @service.execute_tool("calculate", expression: "1 + 1")
      end
    end
  end

  test "namespaced calls keep their offered name and dispatch the bare MCP name" do
    @agent.tools = [ "mcp__host__healthcheck" ]
    root = ActiveAgent::Telemetry::Span.new("agent", trace_id: @run.trace_id, span_type: :root)
    @service.instance_variable_set(:@root_span, root)
    client = Client.new([ "healthcheck" ])

    ActionAgent::MCPClient.stub(:new, client) do
      assert_equal [ "mcp__host__healthcheck" ], @service.resolved_tool_schemas.map { |definition| definition[:name] }
      @service.execute_tool("mcp__host__healthcheck", service: "database")
    end

    assert_equal [ [ "healthcheck", { service: "database" } ] ], client.calls
    assert_equal "mcp__host__healthcheck", @run.reload.logs.first["label"]
    attributes = root.children.first.to_h["attributes"]
    assert_equal "host", attributes["tool.mcp_server"]
    assert_equal "mcp", attributes["tool.origin"]
  end

  test "an enabled MCP claim takes precedence over toolbox functions" do
    @agent.tools = [ "code" ]
    client = Client.new([ "calculate" ])

    ActionAgent::MCPClient.stub(:new, client) do
      assert_equal "Host calculate", @service.resolved_tool_schemas.first[:description]
      assert_equal client.result, @service.execute_tool("calculate", expression: "1 + 1")
    end
    assert_equal [ [ "calculate", { expression: "1 + 1" } ] ], client.calls
  end

  test "builtin categories and exact function names work without enabled MCP servers" do
    @agent.tools = %w[code calculate memory]
    @agent.mcp_servers = []

    assert_equal %w[calculate save_memory recall_memory], @service.resolved_tool_schemas.map { |definition| definition[:name] }
    assert_equal 2, @service.execute_tool("calculate", expression: "1 + 1")[:result]
    saved = @service.execute_tool("save_memory", content: "Remember the healthcheck")
    assert saved[:saved]
    assert_equal "Remember the healthcheck", @service.execute_tool("recall_memory")[:entries].first[:content]
  end

  test "an exact host tool takes precedence over a builder category with the same name" do
    @agent.tools = [ "memory" ]
    client = Client.new([ "memory" ])

    ActionAgent::MCPClient.stub(:new, client) do
      assert_equal [ "memory" ], @service.resolved_tool_schemas.map { |definition| definition[:name] }
      assert_equal client.result, @service.execute_tool("memory", service: "database")
    end
    assert_equal [ [ "memory", { service: "database" } ] ], client.calls
  end

  test "unresolved declarations fail before generation and are recorded as execution errors" do
    @agent.tools = %w[code healthcheck unknown_tool]
    @agent.mcp_servers = []

    @service.stub(:generate!, -> { flunk "The provider must not run with a partial tool roster" }) do
      error = assert_raises(ActionAgent::AgentExecutionService::ToolNotConfiguredError) { @service.call }
      assert_includes error.message, "healthcheck, unknown_tool"
      assert_includes error.message, "MCP server"
    end

    assert @run.reload.logs.any? { |event| event["status"] == "error" }
    trace = ActionAgent::TelemetryTrace.find_by!(trace_id: @run.trace_id)
    assert_equal "ERROR", trace.status
  end

  test "a synchronous run with an unbound tool fails instead of fabricating an answer" do
    @agent.update!(tools: [ "unknown_tool" ], mcp_servers: [])

    run = @agent.test_execute("Run a healthcheck")

    assert run.failed?
    assert_nil run.output
    assert_includes run.error_message, "unknown_tool"
  end

  test "MCP tool errors and transport exceptions reach error events without toolbox fallback" do
    @agent.tools = [ "calculate" ]
    client = Client.new([ "calculate" ])
    client.result = { text: "Host database unavailable", is_error: true }

    ActionAgent::MCPClient.stub(:new, client) do
      assert_equal client.result, @service.execute_tool("calculate", expression: "1 + 1")
      client.result = ActionAgent::MCPClient::Error.new("Connection lost")
      result = @service.execute_tool("calculate", expression: "1 + 1")
      assert_includes result[:error], "Connection lost"
    end

    errors = @run.reload.logs.select { |event| event["status"] == "error" }
    assert_equal 2, errors.size
    assert_equal "Host database unavailable", errors.first["detail"]
    assert_equal 2, client.calls.size
  end
end
