# frozen_string_literal: true

require "test_helper"

# Which traces belong to an agent. An observed agent is registered from an
# application's own class name, one agent per action, so it owns the traces
# AgentRegistrar attributed to it and the unattributed ones carrying its
# service, class and action. Every other agent owns the traces reported under
# `Agent#telemetry_agent_class`.
class AgentTelemetryTracesTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::AgentContext.delete_all
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::Agent.delete_all
    @agent_scope_resolver = ActionAgent.agent_scope_resolver
  end

  def teardown
    ActionAgent.agent_scope_resolver = @agent_scope_resolver
  end

  def report_trace(agent_class:, action:, service_name: "support-desk")
    ActionAgent::TelemetryTrace.create_from_payload({
      "trace_id" => SecureRandom.hex(16), "service_name" => service_name, "environment" => "production",
      "timestamp" => Time.current.iso8601(6),
      "spans" => [ {
        "span_id" => "r1", "parent_span_id" => nil, "name" => "#{agent_class}.#{action}",
        "type" => "root", "duration_ms" => 900.0, "status" => "OK",
        "attributes" => { "agent.class" => agent_class, "agent.action" => action }
      } ]
    })
  end

  def unattributed(trace)
    trace.tap { |record| record.update_columns(agent_id: nil) }
  end

  def observed(agent_class, action)
    ActionAgent::Agent.observed_agents.find_by!(agent_class_name: agent_class, action_name: action)
  end

  test "an observed agent's traces are its attributed ones and the unattributed ones with its identity" do
    respond = [ report_trace(agent_class: "SupportBot", action: "respond") ]
    respond << unattributed(report_trace(agent_class: "SupportBot", action: "respond"))
    title = [ report_trace(agent_class: "SupportBot", action: "title") ]
    title << unattributed(report_trace(agent_class: "SupportBot", action: "title"))
    unattributed(report_trace(agent_class: "SupportBot", action: "respond", service_name: "billing"))

    assert_equal respond.map(&:id).sort, observed("SupportBot", "respond").telemetry_traces.ids.sort
    assert_equal title.map(&:id).sort, observed("SupportBot", "title").telemetry_traces.ids.sort
  end

  test "an observed agent's traces stay within the relation they are selected from" do
    report_trace(agent_class: "SupportBot", action: "respond")
    kept = report_trace(agent_class: "SupportBot", action: "respond")
    kept.update_columns(status: "ERROR")

    scope = ActionAgent::TelemetryTrace.with_errors

    assert_equal [ kept.id ], observed("SupportBot", "respond").telemetry_traces(scope).ids
  end

  test "the class an agent's traces report under" do
    report_trace(agent_class: "SupportBot", action: "respond")
    authored = ActionAgent::Agent.create!(name: "Support Hub", provider: "openai", model: "gpt-4o-mini")
    mirrored = ActionAgent::Agent.create!(name: "Help Desk", agent_class_name: "HelpDesk", provider: "openai", model: "gpt-4o-mini")

    assert_equal "SupportBot", observed("SupportBot", "respond").reported_agent_class
    assert_equal "SupportHubAgent", authored.reported_agent_class
    assert_equal "HelpDeskAgent", mirrored.reported_agent_class
  end

  test "an authored agent's traces are every trace reported under its class, attributed or not" do
    agent = ActionAgent::Agent.create!(name: "Support Hub", provider: "openai", model: "gpt-4o-mini")
    first = report_trace(agent_class: "SupportHubAgent", action: "respond")
    second = report_trace(agent_class: "SupportHubAgent", action: "summarize")
    report_trace(agent_class: "SupportBot", action: "respond")

    assert_equal [ first.id, second.id ].sort, agent.telemetry_traces.ids.sort
  end

  test "the interactions list filtered to an observed agent carries its unattributed traces" do
    attributed = report_trace(agent_class: "SupportBot", action: "respond")
    earlier = unattributed(report_trace(agent_class: "SupportBot", action: "respond"))
    unattributed(report_trace(agent_class: "SupportBot", action: "title"))
    agent = observed("SupportBot", "respond")

    get "/activeagents/api/interactions", params: { agent_id: agent.id }

    assert_response :success
    ids = JSON.parse(response.body)["interactions"].map { |row| row["id"] }
    assert_equal [ "trace-#{attributed.id}", "trace-#{earlier.id}" ].sort, ids.sort
  end

  # --- GET /api/traces?agent_id= ------------------------------------------------

  def traces(**params)
    get "/activeagents/api/traces", params: params
    assert_response :success
    JSON.parse(response.body)
  end

  test "the traces list for an observed agent is its traces, and names only their class" do
    attributed = report_trace(agent_class: "SupportBot", action: "respond")
    earlier = unattributed(report_trace(agent_class: "SupportBot", action: "respond"))
    report_trace(agent_class: "SupportBot", action: "title")
    report_trace(agent_class: "BillingAgent", action: "refund")
    agent = observed("SupportBot", "respond")

    body = traces(agent_id: agent.id)

    assert_equal [ attributed.id, earlier.id ].sort, body["traces"].map { |trace| trace["id"] }.sort
    assert_equal [ "SupportBot" ], body["agents"]
    assert_equal({ "SupportBot" => agent.id }, body["agent_ids"])
  end

  test "the traces list for an authored agent is what its class selects" do
    agent = ActionAgent::Agent.create!(name: "Support Hub", provider: "openai", model: "gpt-4o-mini")
    report_trace(agent_class: "SupportHubAgent", action: "respond")
    report_trace(agent_class: "SupportHubAgent", action: "summarize")
    report_trace(agent_class: "SupportBot", action: "respond")

    by_class = traces(agent: "SupportHubAgent")["traces"].map { |trace| trace["id"] }

    assert_equal 2, by_class.size
    assert_equal by_class.sort, traces(agent_id: agent.id)["traces"].map { |trace| trace["id"] }.sort
  end

  test "the traces list answers 404 for an agent the caller cannot see" do
    report_trace(agent_class: "SupportBot", action: "respond")
    theirs = observed("SupportBot", "respond")
    theirs.update_columns(user_id: 802)
    ActionAgent.agent_scope_resolver = ->(owner) { ActionAgent::Agent.where(user_id: owner&.id) }

    get "/activeagents/api/traces", params: { agent_id: theirs.id }

    assert_response :not_found
    assert_not_includes response.body, "SupportBot"
  end
end
