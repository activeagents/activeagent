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
    # Live checkout runtimes are listed beside the catalog, so one left over
    # would change how many services a roster has.
    ActionAgent::SandboxSession.delete_all
    # The dummy app declares no schema tools; Post's stand in for a host's
    # (find_posts, count_posts, get_post).
    @previous_schema_tools = ActionAgent.schema_tools
    ActionAgent.schema_tools = [ ActiveAgent::SchemaTools.define(Post, filterable: %i[published], returns: %i[id title]) ]
  end

  teardown do
    ActiveAgent::SchemaTools.undefine(Post)
    ActionAgent.schema_tools = @previous_schema_tools
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

  test "a tool the agent class declares in code is reported with its usage and is not editable" do
    agent = create_agent(agent_class_name: "SupportHubAgent")
    create_trace(
      agent_class: "SupportHubAgent",
      declared: [ { "name" => "refund_invoice", "description" => "Refund an invoice in full." } ],
      calls: [ { name: "refund_invoice", duration: 13.0 } ]
    )

    tool = tool_named(roster_for(agent), "refund_invoice")

    assert_equal "agent_defined", tool["source"]
    assert_equal "Refund an invoice in full.", tool["description"]
    assert_equal 1, tool["calls"]
    assert_equal 13, tool["avg_duration_ms"]
    # The class offers it whatever the roster says, so the dashboard reports
    # rather than selects: a checkbox here could not add or remove the tool.
    assert tool["enabled"]
    assert_equal false, tool["editable"]
  end

  test "a schema tool is on while the roster names it, off when it does not, and switchable either way" do
    agent = create_agent(agent_class_name: "SupportHubAgent", tools: [ "find_posts" ])
    create_trace(
      agent_class: "SupportHubAgent",
      declared: [ { "name" => "find_posts", "description" => "Find posts matching the given filters." } ],
      calls: [ { name: "find_posts", duration: 13.0 } ]
    )

    on = tool_named(roster_for(agent), "find_posts")

    assert_equal "agent_defined", on["source"]
    assert on["enabled"]
    assert on["editable"]
    assert_equal 1, on["calls"]

    agent.update!(tools: [])
    off = tool_named(roster_for(agent), "find_posts")

    # The window still shows the tool offered and called; that is history.
    # What a generation would be offered now is the roster — the reading
    # AgentToolbox takes, and the one the evaluation runner follows.
    assert_equal false, off["enabled"]
    assert off["editable"]
    assert_equal 1, off["calls"]
    assert_empty ActionAgent::AgentToolbox.definitions_for(agent.tools)
  end

  test "every schema tool the host declares has a row, off unless the roster names it" do
    hub = create_agent(agent_class_name: "SupportHubAgent")
    hub.update!(tools: [])
    # Named after the model, so the convention seeds Post's tools on create.
    posts = create_agent(name: "Post Agent", agent_class_name: "PostAgent")

    off = tool_named(roster_for(hub), "find_posts")

    assert_equal "agent_defined", off["source"]
    assert_equal false, off["enabled"]
    assert off["editable"]
    assert_equal 0, off["calls"]
    assert_nil off["last_seen"]
    assert off["description"].present?

    assert_equal %w[count_posts find_posts get_post], posts.tools.sort
    assert tool_named(roster_for(posts), "find_posts")["enabled"]
  end

  test "saving the roster switches what a generation is offered" do
    agent = create_agent(agent_class_name: "SupportHubAgent", tools: [ "find_posts", "memory" ])
    offered = -> { ActionAgent::AgentToolbox.definitions_for(agent.reload.tools).map { |definition| definition[:name].to_s } }

    patch "/activeagents/api/agents/#{agent.id}", params: { agent: { tools: [ "memory" ] } }

    assert_response :success
    assert_equal false, tool_named(roster_for(agent), "find_posts")["enabled"]
    assert_not_includes offered.call, "find_posts"

    patch "/activeagents/api/agents/#{agent.id}", params: { agent: { tools: [ "memory", "find_posts" ] } }

    assert_response :success
    assert tool_named(roster_for(agent), "find_posts")["enabled"]
    assert_includes offered.call, "find_posts"
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

  test "every service the dashboard calls over http reads as Streamable HTTP with its url" do
    previous = ActionAgent.mcp_catalog
    ActionAgent.mcp_catalog = [
      { key: "records", name: "Records", transport: "http", url: "https://host.example/mcp/records" },
      { key: "booking", name: "Booking", transport: "streamable_http", url: "https://booking.example/mcp" },
      { key: "legacy", name: "Legacy", transport: "sse", url: "https://legacy.example/sse" }
    ]

    body = roster_for(create_agent)

    assert_equal "Streamable HTTP · https://host.example/mcp/records", service_named(body, "records")["transport"]
    assert_equal "Streamable HTTP · https://booking.example/mcp", service_named(body, "booking")["transport"]
    assert_equal "Streamable HTTP · https://legacy.example/sse", service_named(body, "legacy")["transport"]
    # A stdio server has no url to call; it is described by its command.
    assert_equal "stdio · npx @modelcontextprotocol/server-slack", service_named(body, "slack")["transport"]
  ensure
    ActionAgent.mcp_catalog = previous
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
