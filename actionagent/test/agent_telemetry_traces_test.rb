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

  def report_trace(agent_class:, action:, service_name: "support-desk", environment: "production")
    ActionAgent::TelemetryTrace.create_from_payload({
      "trace_id" => SecureRandom.hex(16), "service_name" => service_name, "environment" => environment,
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

  def all_traces
    ActionAgent::TelemetryTrace.all
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

    assert_equal respond.map(&:id).sort, observed("SupportBot", "respond").telemetry_traces(all_traces).ids.sort
    assert_equal title.map(&:id).sort, observed("SupportBot", "title").telemetry_traces(all_traces).ids.sort
  end

  # The dummy app's traces carry no account, so `environment` stands in for
  # the tenant a multi-tenant caller narrows its relation to with `for_account`.
  test "an observed agent's traces, unattributed ones included, stay within the caller's relation" do
    mine = [ report_trace(agent_class: "SupportBot", action: "respond", environment: "tenant-a") ]
    mine << unattributed(report_trace(agent_class: "SupportBot", action: "respond", environment: "tenant-a"))
    unattributed(report_trace(agent_class: "SupportBot", action: "respond", environment: "tenant-b"))

    tenant = ActionAgent::TelemetryTrace.for_environment("tenant-a")

    assert_equal mine.map(&:id).sort, observed("SupportBot", "respond").telemetry_traces(tenant).ids.sort
  end

  test "an observed agent registered from an empty action reads its unattributed traces" do
    attributed = report_trace(agent_class: "SupportBot", action: "")
    earlier = unattributed(report_trace(agent_class: "SupportBot", action: ""))
    agent = ActionAgent::Agent.observed_agents.find_by!(agent_class_name: "SupportBot")

    assert_nil agent.action_name
    assert_equal [ attributed.id, earlier.id ].sort, agent.telemetry_traces(all_traces).ids.sort
  end

  test "an observed agent registered again after a delete keeps the traces recorded before it" do
    before = report_trace(agent_class: "SupportBot", action: "respond")
    observed("SupportBot", "respond").destroy!
    after = report_trace(agent_class: "SupportBot", action: "respond")

    assert_equal [ before.id, after.id ].sort, observed("SupportBot", "respond").telemetry_traces(all_traces).ids.sort
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

    assert_equal [ first.id, second.id ].sort, agent.telemetry_traces(all_traces).ids.sort
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

  test "trace statistics and buckets include errors beyond the capped details" do
    now = Time.current.change(usec: 0)
    travel_to now do
      rows = 1001.times.map do |index|
        { trace_id: "window-#{index}", service_name: "synthetic", timestamp: now - (index + 1).seconds,
          status: index == 1000 ? "ERROR" : "OK", total_duration_ms: 100.0,
          agent_class: "AuditAgent", agent_action: "respond", spans: [], created_at: now, updated_at: now }
      end
      ActionAgent::TelemetryTrace.insert_all!(rows)
      body = traces(minutes: 60, bucket_seconds: 120)

      assert_equal 500, body["traces"].size
      assert_equal 1001, body["total_count"]
      assert_equal 500, body["returned_count"]
      assert_equal true, body["truncated"]
      assert_equal 1001, body.dig("summary", "requests")
      assert_equal 1, body.dig("summary", "errors")
      assert_equal 1001, body["buckets"].sum { |bucket| bucket["requests"] }
      assert_equal 1, body["buckets"].sum { |bucket| bucket["errors"] }
      assert_equal 30, body["buckets"].size
      assert_equal 1000, traces(minutes: 60, limit: 99999)["returned_count"]
    end
  end

  test "latency is averaged per recorded request and bucket boundaries are half open" do
    now = Time.current.change(usec: 0)
    travel_to now do
      base = { service_name: "synthetic", status: "OK", agent_class: "AuditAgent", spans: [], created_at: now, updated_at: now }
      rows = [ { timestamp: now - 120.seconds, total_duration_ms: 1000.0 } ]
      rows += Array.new(9) { { timestamp: now - 30.seconds, total_duration_ms: 100.0 } }
      rows += [ { timestamp: now - 60.seconds, total_duration_ms: nil } ]
      rows += [ { timestamp: now, total_duration_ms: 99999.0 }, { timestamp: now - 121.seconds, total_duration_ms: 99999.0 } ]
      ActionAgent::TelemetryTrace.insert_all!(rows.each_with_index.map { |row, index| base.merge(row).merge(trace_id: "latency-#{index}") })
      body = traces(minutes: 2, bucket_seconds: 60)

      assert_equal 11, body["total_count"]
      assert_equal 190, body.dig("summary", "avg_latency_ms")
      assert_equal [ 1, 10 ], body["buckets"].map { |bucket| bucket["requests"] }
      assert_equal [ 1000, 100 ], body["buckets"].map { |bucket| bucket["avg_latency_ms"] }
      assert_equal (now.to_f * 1000).to_i, body["window_end_ms"]
      assert_equal ((now - 120.seconds).to_f * 1000).to_i, body["window_start_ms"]
    end
  end

  test "trace aggregates share the list filters and caller's tenant scope" do
    mine = report_trace(agent_class: "SupportBot", action: "respond", service_name: "billing", environment: "mine")
    mine.update!(status: "ERROR")
    report_trace(agent_class: "SupportBot", action: "respond", service_name: "other", environment: "mine")
    report_trace(agent_class: "OtherBot", action: "respond", service_name: "billing", environment: "mine").update!(status: "ERROR")
    report_trace(agent_class: "SupportBot", action: "respond", service_name: "billing", environment: "theirs").update!(status: "ERROR")
    tenant = ->(_owner) { ActionAgent::TelemetryTrace.where(environment: "mine") }

    body = ActionAgent::TelemetryTrace.stub(:for_account, tenant) { traces(agent: "SupportBot", service: "billing", status: "error") }
    assert_equal [ mine.id ], body["traces"].map { |trace| trace["id"] }
    assert_equal 1, body["total_count"]
    assert_equal false, body["truncated"]
    assert_equal 1, body.dig("summary", "requests")
    assert_equal 1, body.dig("summary", "errors")
    assert_equal 1, body["buckets"].sum { |bucket| bucket["requests"] }
    refute body["buckets"].any? { |bucket| bucket.dig("agents", "OtherBot") }
  end

  test "an empty window has zero totals and a bounded zero-filled chart" do
    body = traces(minutes: 60, bucket_seconds: 120)
    assert_equal 0, body["total_count"]
    assert_equal false, body["truncated"]
    assert_equal({ "requests" => 0, "errors" => 0, "avg_latency_ms" => 0, "throughput_per_minute" => 0.0 }, body["summary"])
    assert_equal 30, body["buckets"].size
    assert body["buckets"].all? { |bucket| bucket["requests"].zero? }

    body = traces(minutes: 129600, bucket_seconds: 0)
    assert_operator body["buckets"].size, :<=, ActionAgent::TraceWindowReport::MAX_BUCKETS
  end

  test "container-valued trace parameters use the shared coercion rules" do
    body = traces(minutes: [ 60, 120 ], limit: { n: 500 }, bucket_seconds: { n: 1 })
    assert_equal 60, body["window_minutes"]
    assert_equal 60, body["bucket_seconds"]
    assert_equal 60, body["buckets"].size
    body = traces(minutes: [ 2 ], bucket_seconds: [ 30, 60 ])
    assert_equal 30, body["bucket_seconds"]
    assert_equal 4, body["buckets"].size
  end
end
