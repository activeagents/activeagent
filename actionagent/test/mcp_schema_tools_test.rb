# frozen_string_literal: true

require "test_helper"

# The host's schema tools served through the MCP facade (#439): a client
# calls find_<records> itself, as the key's caller, rather than asking an
# agent to. One roster, two transports.
class McpSchemaToolsTest < ActionDispatch::IntegrationTest
  class RecordTools
    def self.model = Struct.new(:name).new("Record")
    def self.tool_names = %w[find_records get_record]
    def self.tool?(name) = tool_names.include?(name.to_s)

    def self.tool_definitions
      [
        { name: "find_records", description: "Find records", parameters: { type: "object", properties: { status: { type: "string" } }, required: [] } },
        { name: "get_record", description: "One record", parameters: { type: "object", properties: { id: { type: "integer" } }, required: [ "id" ] } }
      ]
    end

    def self.call(name, actor: nil, **arguments)
      return { error: "`#{arguments.keys.first}` is not a filterable attribute" } if arguments.key?(:colour)
      raise ActiveAgent::NotAuthorized.new(action: name) if actor == :forbidden

      { called: name, actor: actor.inspect, arguments: arguments, results: [] }
    end
  end

  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::ApiKey.delete_all
    @agent = ActionAgent::Agent.create!(name: "Records", slug: "records", provider: "mock", model: "mock", status: :active)
    @key = ActionAgent::ApiKey.create!(name: "Test key")
    @previous_tools = ActionAgent.schema_tools
    ActionAgent.schema_tools = [ RecordTools ]
  end

  def teardown
    ActionAgent.schema_tools = @previous_tools
    ActionAgent.mcp_schema_tools = nil
    ActionAgent.agent_actor_resolver = nil
  end

  def rpc(method, params = {})
    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{@key.token}" }
    JSON.parse(response.body)
  end

  test "tools/list offers each schema tool beside the agents, with its own parameter schema" do
    tools = rpc("tools/list").dig("result", "tools")
    names = tools.map { |tool| tool["name"] }

    assert_includes names, "run_records"
    assert_includes names, "find_records"
    find = tools.find { |tool| tool["name"] == "find_records" }
    assert_equal "Find records", find["description"]
    assert_equal "object", find.dig("inputSchema", "type")
    assert_includes find.dig("inputSchema", "properties").keys, "status"
  end

  test "tools/call runs a schema tool as the caller the host resolves, with the client's arguments" do
    ActionAgent.agent_actor_resolver = ->(_controller) { :alice }

    body = rpc("tools/call", { name: "find_records", arguments: { status: "held" } })

    assert_nil body["error"]
    result = body.dig("result", "structuredContent")
    assert_equal "find_records", result["called"]
    assert_equal ":alice", result["actor"]
    assert_equal({ "status" => "held" }, result["arguments"])
    assert_equal result.to_json, body.dig("result", "content", 0, "text")
    assert_nil body.dig("result", "isError")
  end

  test "a client cannot name the caller through the arguments" do
    ActionAgent.agent_actor_resolver = ->(_controller) { :alice }

    result = rpc("tools/call", { name: "find_records", arguments: { actor: "root", current_user: 1, status: "held" } }).dig("result", "structuredContent")

    assert_equal ":alice", result["actor"]
    assert_equal({ "status" => "held" }, result["arguments"])
  end

  test "with no resolver and no owner model the call is unattributed, never widened" do
    result = rpc("tools/call", { name: "find_records", arguments: {} }).dig("result", "structuredContent")

    assert_equal "nil", result["actor"]
  end

  test "a boundary violation is a tool result the client can correct, not a transport error" do
    body = rpc("tools/call", { name: "find_records", arguments: { colour: "red" } })

    assert_nil body["error"]
    assert_equal true, body.dig("result", "isError")
    assert_match(/not a filterable attribute/, body.dig("result", "content", 0, "text"))
  end

  test "a refusal from the host's scope answers as a JSON-RPC forbidden error" do
    ActionAgent.agent_actor_resolver = ->(_controller) { :forbidden }

    body = rpc("tools/call", { name: "find_records", arguments: {} })

    assert_equal(-32003, body.dig("error", "code"))
    assert_nil body["result"]
  end

  test "an unknown tool is still unknown" do
    body = rpc("tools/call", { name: "find_nothing", arguments: {} })

    assert_equal(-32602, body.dig("error", "code"))
  end

  test "the host can keep its schema tools behind agents" do
    ActionAgent.mcp_schema_tools = false

    names = rpc("tools/list").dig("result", "tools").map { |tool| tool["name"] }
    assert_not_includes names, "find_records"
    assert_includes names, "run_records"

    assert_equal(-32602, rpc("tools/call", { name: "find_records", arguments: {} }).dig("error", "code"))
  end

  test "a direct read needs no execution switch and spends no execution quota" do
    ActionAgent.execution_enabled = false
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind) { recorded << kind }

    body = rpc("tools/call", { name: "get_record", arguments: { id: 1 } })

    assert_nil body["error"]
    assert_equal "get_record", body.dig("result", "structuredContent", "called")
    assert_empty recorded
  ensure
    ActionAgent.execution_enabled = nil
    ActionAgent.usage_recorder = nil
  end
end
