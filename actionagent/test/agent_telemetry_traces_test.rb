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
end
