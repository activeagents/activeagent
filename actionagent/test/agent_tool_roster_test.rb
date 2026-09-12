# frozen_string_literal: true

require "test_helper"

# The agent editor's Tools tab roster, exercised through the engine mounted
# in the dummy app at /activeagents.
#
# The roster is derived rather than registered: the agent's own configuration
# says what is enabled, and ToolDiscovery says what was called. These cover
# the seam between the two — which group a tool lands in, what "enabled"
# means per group, and how a partially allowed MCP service reads.
class AgentToolRosterTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::AgentContext.delete_all
  end

  def create_agent(**attributes)
    ActionAgent::Agent.create!(
      { name: "Support Hub", provider: "openai", model: "gpt-4o-mini" }.merge(attributes)
    )
  end

  # A trace of one generation: the roster it offered, and the tools the model
  # then called — the two readings ToolDiscovery takes from a single trace.
  def create_trace(agent_class:, declared: [], calls: [])
    spans = [ {
      "span_id" => "r1", "parent_span_id" => nil, "name" => "#{agent_class}.respond",
      "type" => "root", "duration_ms" => 900.0, "status" => "OK",
      "attributes" => { "agent.class" => agent_class, "agent.action" => "respond" }
    } ]

    if declared.any?
      spans << {
        "span_id" => "p1", "parent_span_id" => "r1", "name" => "prompt", "type" => "prompt",
        "duration_ms" => 5.0, "status" => "OK",
        "attributes" => { "prompt.input.tools" => declared.to_json }
      }
    end

    calls.each_with_index do |call, index|
      spans << {
        "span_id" => "t#{index}", "parent_span_id" => "r1", "name" => "tool.#{call[:name]}",
        "type" => "tool", "duration_ms" => call.fetch(:duration, 13.0),
        "status" => call[:error] ? "ERROR" : "OK",
        "attributes" => { "tool.name" => call[:name] }.merge(call[:error] ? { "error.message" => call[:error] } : {})
      }
    end

    ActionAgent::TelemetryTrace.create_from_payload({
      "trace_id" => SecureRandom.hex(16), "service_name" => "support-hub",
      "environment" => "production", "timestamp" => Time.current.iso8601(6), "spans" => spans
    })
  end

  def roster_for(agent, params = {})
    get "/activeagents/api/agents/#{agent.id}/tool_roster", params: params
    assert_response :success
    JSON.parse(response.body)
  end

  def service_named(body, key)
    body["services"].find { |service| service["key"] == key }
  end

  def tool_named(body, name)
    body["tools"].find { |tool| tool["name"] == name }
  end

  test "schema-derived tools are reported with their usage and are not editable" do
    agent = create_agent(agent_class_name: "SupportHubAgent")
    create_trace(
      agent_class: "SupportHubAgent",
      declared: [ { "name" => "find_tickets", "description" => "Find tickets matching the given filters." } ],
      calls: [ { name: "find_tickets", duration: 13.0 } ]
    )

    tool = tool_named(roster_for(agent), "find_tickets")

    assert_equal "agent_defined", tool["source"]
    assert_equal "Find tickets matching the given filters.", tool["description"]
    assert_equal 1, tool["calls"]
    assert_equal 13, tool["avg_duration_ms"]
    # The agent class declares them, so the dashboard reports rather than
    # selects: a checkbox here could not add or remove the tool.
    assert tool["enabled"]
    assert_equal false, tool["editable"]
  end

  test "another agent's traffic stays out of this agent's roster" do
    agent = create_agent(agent_class_name: "SupportHubAgent")
    create_trace(agent_class: "BillingAgent", calls: [ { name: "refund_invoice" } ])

    assert_nil tool_named(roster_for(agent), "refund_invoice")
  end

  test "dashboard capabilities carry their enabled state and the usage of the functions they expose" do
    agent = create_agent(agent_class_name: "SupportHubAgent", tools: [ "memory" ])
    create_trace(agent_class: "SupportHubAgent", calls: [
      { name: "save_memory", duration: 10.0 },
      { name: "recall_memory", duration: 30.0 }
    ])

    body = roster_for(agent)
    memory = tool_named(body, "memory")

    assert_equal "dashboard", memory["source"]
    assert memory["enabled"]
    assert memory["editable"]
    # One checkbox over the two functions the capability exposes.
    assert_equal 2, memory["calls"]
    assert_equal 20, memory["avg_duration_ms"]
    assert_equal "Reads and writes durable notes across runs of this agent.", memory["description"]
    assert_equal false, tool_named(body, "terminal")["enabled"]
    # A capability's own functions belong to it, not to the agent-defined group.
    assert_nil tool_named(body, "save_memory")
  end

  test "every catalog service is listed, and the ones the agent names are enabled" do
    agent = create_agent(mcp_servers: [ "playwright" ])

    body = roster_for(agent)
    playwright = service_named(body, "playwright")

    assert_equal ActionAgent::MCPCatalog.keys.size, body["services"].size
    assert playwright["enabled"]
    assert_equal "configured", playwright["status"]
    assert_equal "sandbox · npx @playwright/mcp@latest", playwright["transport"]
    # Offered tools come from the catalog; all of them, since the entry
    # names no allow-list.
    assert_includes playwright["tools"].map { |tool| tool["name"] }, "browser_navigate"
    assert playwright["tools"].all? { |tool| tool["enabled"] }
    assert_equal false, service_named(body, "git")["enabled"]
    assert_equal "available", service_named(body, "git")["status"]
  end

  test "a service entry naming some of its tools offers only those" do
    agent = create_agent(mcp_servers: [ { "key" => "playwright", "tools" => [ "browser_navigate" ] } ])

    tools = service_named(roster_for(agent), "playwright")["tools"].index_by { |tool| tool["name"] }

    assert tools["browser_navigate"]["enabled"]
    assert_equal false, tools["browser_click"]["enabled"]
  end

  test "a service with traffic reads as active and carries its calls and errors" do
    agent = create_agent(agent_class_name: "SupportHubAgent", mcp_servers: [ "playwright" ])
    create_trace(agent_class: "SupportHubAgent", calls: [
      { name: "mcp__playwright__browser_navigate", duration: 820.0 },
      { name: "mcp__playwright__browser_click", error: "element not found" }
    ])

    service = service_named(roster_for(agent), "playwright")

    assert_equal "active", service["status"]
    assert_equal 2, service["calls"]
    assert_equal 1, service["errors"]
    assert_equal 820, service["tools"].find { |tool| tool["name"] == "browser_navigate" }["avg_duration_ms"]
    # MCP tools are never roster rows: they belong to the service that
    # offers them, which is where they are edited.
    assert_nil tool_named(roster_for(agent), "browser_navigate")
  end

  test "usage is reported as unavailable when nothing was recorded in the window" do
    agent = create_agent(agent_class_name: "SupportHubAgent")

    assert_equal false, roster_for(agent)["usage_available"]

    create_trace(agent_class: "SupportHubAgent", calls: [ { name: "find_tickets" } ])

    assert roster_for(agent)["usage_available"]
  end

  test "the window is scoped by the hours parameter" do
    agent = create_agent(agent_class_name: "SupportHubAgent")

    assert_equal 24, roster_for(agent, hours: 24)["window_hours"]
  end

  test "saving a roster keeps per-service tool allow-lists" do
    agent = create_agent(tools: [ "memory" ])

    patch "/activeagents/api/agents/#{agent.id}", params: {
      agent: {
        tools: [ "memory", "search" ],
        mcp_servers: [ { key: "playwright", name: "Playwright", tools: [ "browser_navigate" ] } ]
      }
    }

    assert_response :success
    agent.reload
    assert_equal [ "memory", "search" ], agent.tools
    assert_equal [ { "key" => "playwright", "name" => "Playwright", "tools" => [ "browser_navigate" ] } ], agent.mcp_servers
  end

  test "an agent saved with bare server names keeps them" do
    agent = create_agent

    patch "/activeagents/api/agents/#{agent.id}", params: { agent: { mcp_servers: [ "playwright" ] } }

    assert_response :success
    assert_equal [ "playwright" ], agent.reload.mcp_servers
  end
end
