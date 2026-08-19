# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# The Tools and MCP Services API, exercised through the engine mounted in the
# dummy app at /activeagents. The inventory is derived rather than
# registered, so these cover each record source it reads and the way they
# combine — including the case where one run writes to several at once.
class ToolDiscoveryApiTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::AgentContext.delete_all
    ActionAgent::SandboxSession.delete_all
  end

  def create_agent(name: "Support", **attributes)
    ActionAgent::Agent.create!(
      { name: name, provider: "openai", model: "gpt-4o-mini" }.merge(attributes)
    )
  end

  # A trace carrying an offered tool roster and/or executed tool spans,
  # shaped the way ActiveAgent's instrumentation emits them.
  def create_trace(agent_class: "SupportAgent", declared: [], calls: [], timestamp: Time.current)
    spans = [
      {
        "span_id" => "r1", "parent_span_id" => nil, "name" => "#{agent_class}.respond",
        "type" => "root", "duration_ms" => 1000.0, "status" => "OK",
        "attributes" => { "agent.class" => agent_class, "agent.action" => "respond" }
      }
    ]

    if declared.any?
      spans << {
        "span_id" => "p1", "parent_span_id" => "r1", "name" => "prompt",
        "type" => "prompt", "duration_ms" => 5.0, "status" => "OK",
        "attributes" => { "prompt.input.tools" => declared.to_json }
      }
    end

    calls.each_with_index do |call, index|
      attributes = { "tool.name" => call[:name] }
      attributes["error.message"] = call[:error] if call[:error]
      attributes["tool.input.args"] = call[:args] if call[:args]
      spans << {
        "span_id" => "t#{index}", "parent_span_id" => "r1", "name" => "tool.#{call[:name]}",
        "type" => "tool", "duration_ms" => call.fetch(:duration, 100.0),
        "status" => call[:error] ? "ERROR" : "OK", "attributes" => attributes
      }
    end

    ActionAgent::TelemetryTrace.create_from_payload(
      {
        "trace_id" => SecureRandom.hex(16), "service_name" => "app",
        "environment" => "production", "timestamp" => timestamp.iso8601(6), "spans" => spans
      }
    )
  end

  def create_context(agent:, tool_calls: [], provenance_tools: nil, tool_messages: [])
    context = ActionAgent::AgentContext.create!(
      agent_name: "SupportAgent", action_name: "respond", contextable: agent
    )
    provenance = { "agent_class" => "SupportAgent" }
    provenance["tools"] = provenance_tools if provenance_tools

    if tool_calls.any? || provenance_tools
      context.generations.create!(
        model: "gpt-4o", provider: "openai", finish_reason: "tool_calls",
        tool_calls: tool_calls, provenance: provenance
      )
    end

    tool_messages.each do |name|
      context.add_tool_message(tool_call_id: SecureRandom.hex(4), tool_name: name, result: "ok")
    end

    context
  end

  def tools_response
    get "/activeagents/api/tools"
    assert_response :success
    JSON.parse(response.body)
  end

  def tool_named(name, body = tools_response)
    body["tools"].find { |row| row["name"] == name }
  end

  # --- sources ----------------------------------------------------------

  test "detects tools called in telemetry spans" do
    create_trace(calls: [ { name: "lookup_order", duration: 200.0 } ])

    tool = tool_named("lookup_order")

    assert_equal 1, tool["calls"]
    assert_equal 200, tool["avg_duration_ms"]
    assert_equal "agent", tool["origin"]
    assert_includes tool["detected_from"], "telemetry"
    assert_includes tool["agents"], "SupportAgent"
  end

  test "attributes namespaced tool calls to their MCP server" do
    create_trace(calls: [ { name: "mcp__playwright__browser_navigate" } ])

    tool = tool_named("mcp__playwright__browser_navigate")

    assert_equal "mcp", tool["origin"]
    assert_equal "playwright", tool["mcp_server"]
    assert_equal "browser_navigate", tool["base_name"]
    assert_equal "MCP · Playwright", tool["source_label"]
  end

  test "detects tools offered in the generation request body but never called" do
    create_trace(declared: [ { "name" => "never_called", "description" => "Offered only", "parameters" => [ "id" ] } ])

    tool = tool_named("never_called")

    assert tool["declared"]
    assert tool["unused"]
    assert_equal 0, tool["calls"]
    assert_equal "Offered only", tool["description"]
    assert_equal [ "id" ], tool["parameters"]
    assert_includes tool["detected_from"], "request"
  end

  test "detects tools from solid_agent generation provenance" do
    create_context(
      agent: create_agent,
      provenance_tools: [ { "name" => "solid_tool", "description" => "From provenance", "parameters" => [ "x" ] } ]
    )

    tool = tool_named("solid_tool")

    assert tool["declared"]
    assert_equal "From provenance", tool["description"]
    assert_includes tool["detected_from"], "provenance"
  end

  test "detects tools from solid_agent tool_calls and tool messages" do
    create_context(
      agent: create_agent,
      tool_calls: [ { "name" => "send_email", "arguments" => { "to" => "a@b.c" } } ],
      tool_messages: [ "send_email" ]
    )

    tool = tool_named("send_email")

    assert_equal 1, tool["requested"]
    assert_equal 1, tool["results"]
    # No telemetry span for this tool, so the count falls back to the
    # strongest signal present rather than reporting zero.
    assert_equal 1, tool["calls"]
    assert_includes tool["detected_from"], "generations"
    assert_includes tool["detected_from"], "messages"
  end

  test "counts a run written to every source only once" do
    agent = create_agent
    create_trace(calls: [ { name: "send_email" } ])
    create_context(agent: agent, tool_calls: [ { "name" => "send_email" } ], tool_messages: [ "send_email" ])

    tool = tool_named("send_email")

    assert_equal 1, tool["calls"], "telemetry is authoritative; generations/messages must not add to it"
    assert_equal 1, tool["traced_calls"]
  end

  test "reports errors and error rate from tool spans" do
    create_trace(calls: [ { name: "flaky_tool", error: "boom" }, { name: "flaky_tool" } ])

    tool = tool_named("flaky_tool")

    assert_equal 2, tool["calls"]
    assert_equal 1, tool["errors"]
    assert_equal 50.0, tool["error_rate"]
    assert_equal "boom", tool["last_error"]
  end

  test "lists tools an agent configured but never called" do
    create_agent(tools: [ "code" ])

    # The "code" capability exposes calculate(); the view lists the real
    # tool name, not the builder's capability label.
    tool = tool_named("calculate")

    assert tool["unused"]
    assert_equal "builtin", tool["origin"]
    assert_includes tool["configured_by"], "Support"
  end

  test "classifies dashboard toolbox tools as builtin" do
    create_trace(calls: [ { name: "web_search" } ])

    tool = tool_named("web_search")

    assert_equal "builtin", tool["origin"]
    assert_equal "Dashboard toolbox", tool["source_label"]
  end

  test "counts only traffic inside the requested window" do
    create_trace(calls: [ { name: "old_tool" } ], timestamp: 10.days.ago, agent_class: "OldAgent")
    create_trace(calls: [ { name: "new_tool" } ])

    get "/activeagents/api/tools", params: { hours: 24 }
    body = JSON.parse(response.body)
    tools = body["tools"].index_by { |row| row["name"] }

    assert_equal 1, tools["new_tool"]["calls"]
    assert_equal 1, body.dig("summary", "total_calls")

    # Aged-out traffic contributes no calls. Whether the tool stays listed
    # at all depends on the install: where AgentRegistrar has recorded the
    # agent behind it, that agent's tools remain part of its configuration,
    # because the window bounds traffic and not configuration. So this
    # asserts the count rather than absence.
    assert_equal 0, tools["old_tool"]["calls"] if tools.key?("old_tool")
  end

  test "filters by origin and by search query" do
    create_trace(calls: [ { name: "mcp__playwright__browser_click" }, { name: "lookup_order" } ])

    get "/activeagents/api/tools", params: { origin: "mcp" }
    assert_equal [ "mcp__playwright__browser_click" ], JSON.parse(response.body)["tools"].map { |row| row["name"] }

    get "/activeagents/api/tools", params: { q: "lookup" }
    assert_equal [ "lookup_order" ], JSON.parse(response.body)["tools"].map { |row| row["name"] }
  end

  test "summarizes the inventory and reports which sources had data" do
    create_trace(
      declared: [ { "name" => "idle_tool", "description" => "never used" } ],
      calls: [ { name: "mcp__playwright__browser_click" } ]
    )

    body = tools_response

    assert_equal 1, body.dig("summary", "active_tools")
    assert_equal 1, body.dig("summary", "mcp_tools")
    assert_equal 1, body.dig("summary", "total_calls")
    assert_equal 1, body.dig("summary", "mcp_servers_active")
    assert body.dig("sources", "telemetry")
    assert_not body.dig("sources", "declared")
  end
end

# The MCP Services API: detected servers unioned with the default catalog,
# and starting a catalog server inside a sandbox.
class McpServersApiTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::SandboxSession.delete_all
  end

  def create_agent(name: "Support", **attributes)
    ActionAgent::Agent.create!(
      { name: name, provider: "openai", model: "gpt-4o-mini" }.merge(attributes)
    )
  end

  def create_trace(tool_names, agent_class: "SupportAgent")
    spans = [
      {
        "span_id" => "r1", "parent_span_id" => nil, "name" => "#{agent_class}.respond",
        "type" => "root", "duration_ms" => 900.0, "status" => "OK",
        "attributes" => { "agent.class" => agent_class, "agent.action" => "respond" }
      }
    ]
    Array(tool_names).each_with_index do |name, index|
      spans << {
        "span_id" => "t#{index}", "parent_span_id" => "r1", "name" => "tool.#{name}",
        "type" => "tool", "duration_ms" => 50.0, "status" => "OK",
        "attributes" => { "tool.name" => name }
      }
    end

    ActionAgent::TelemetryTrace.create_from_payload(
      {
        "trace_id" => SecureRandom.hex(16), "service_name" => "app",
        "environment" => "production", "timestamp" => Time.current.iso8601(6), "spans" => spans
      }
    )
  end

  def servers_response
    get "/activeagents/api/mcp_servers"
    assert_response :success
    JSON.parse(response.body)
  end

  def server_named(key, body = servers_response)
    body["servers"].find { |server| server["key"] == key }
  end

  test "lists the default catalog even with no traffic" do
    body = servers_response

    keys = body["servers"].map { |server| server["key"] }
    assert_includes keys, "playwright"
    assert_includes keys, "github"

    playwright = server_named("playwright", body)
    assert_equal "available", playwright["status"]
    assert_equal 0, playwright["calls"]
    assert playwright["known"]
    assert playwright["launchable"]
    # A catalog entry advertises its tools before any have been called.
    assert_includes playwright["tools"], "browser_navigate"
  end

  test "marks a server active once its tools are called" do
    create_trace([ "mcp__playwright__browser_navigate", "mcp__playwright__browser_click" ])

    playwright = server_named("playwright")

    assert_equal "active", playwright["status"]
    assert_equal 2, playwright["calls"]
    assert_equal 2, playwright["tool_count"]
    assert_equal [ "browser_click", "browser_navigate" ], playwright["tools"]
    assert_includes playwright["agents"], "SupportAgent"
  end

  test "surfaces a detected server that is not in the catalog" do
    create_trace([ "mcp__acme_internal__do_thing" ])

    acme = server_named("acme_internal")

    assert_not_nil acme, "a server seen in traffic should be listed even when undocumented"
    assert_equal "active", acme["status"]
    assert_not acme["known"]
    assert_not acme["launchable"]
  end

  test "marks a server configured when an agent declares it without traffic" do
    create_agent(mcp_servers: [ "filesystem" ])

    filesystem = server_named("filesystem")

    assert_equal "configured", filesystem["status"]
    assert_includes filesystem["configured_by"], "Support"
  end

  test "accepts an agent mcp_servers entry given as a hash" do
    create_agent(mcp_servers: [ { "name" => "git", "url" => "http://localhost:9000" } ])

    assert_equal "configured", server_named("git")["status"]
  end

  test "summarizes servers by status" do
    create_trace([ "mcp__playwright__browser_navigate" ])
    create_agent(mcp_servers: [ "filesystem" ])

    summary = servers_response["summary"]

    assert_equal 1, summary["active"]
    assert_equal 1, summary["configured"]
    assert summary["available"].positive?
    assert_equal 1, summary["total_calls"]
  end

  test "shows one server with the tools detected for it" do
    create_trace([ "mcp__playwright__browser_navigate" ])

    get "/activeagents/api/mcp_servers/playwright"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "playwright", body.dig("server", "key")
    assert_equal [ "mcp__playwright__browser_navigate" ], body["tools"].map { |tool| tool["name"] }
  end

  test "returns not found for an unknown server" do
    get "/activeagents/api/mcp_servers/nope"

    assert_response :not_found
  end

  test "launches a launchable server in a sandbox" do
    assert_difference -> { ActionAgent::SandboxSession.count }, 1 do
      post "/activeagents/api/mcp_servers/playwright/launch"
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "playwright", body.dig("server", "key")
    assert_equal [ "playwright" ], body.dig("sandbox", "mcp_servers")

    sandbox = ActionAgent::SandboxSession.order(:created_at).last
    assert_equal "playwright_mcp", sandbox.sandbox_type
    assert_equal [ "playwright" ], sandbox.mcp_servers
  end

  test "refuses to launch a server that needs credentials" do
    assert_no_difference -> { ActionAgent::SandboxSession.count } do
      post "/activeagents/api/mcp_servers/github/launch"
    end

    assert_response :unprocessable_entity
    assert_match(/GITHUB_TOKEN/, JSON.parse(response.body)["reason"])
  end

  test "lists running sandboxes so a launched server is not started twice" do
    post "/activeagents/api/mcp_servers/filesystem/launch"
    assert_response :created

    running = servers_response["sandboxes"]

    assert_equal 1, running.size
    assert_equal [ "filesystem" ], running.first["mcp_servers"]
  end

  test "a catalog server resolves to its entry and its launchability" do
    assert ActionAgent::MCPCatalog.launchable?("playwright")
    assert_not ActionAgent::MCPCatalog.launchable?("github")
    assert_nil ActionAgent::MCPCatalog.find("nope")
    assert_equal "Playwright", ActionAgent::MCPCatalog.display_name("playwright")
    # An unknown key displays as itself rather than blank.
    assert_equal "acme", ActionAgent::MCPCatalog.display_name("acme")
  end
end
