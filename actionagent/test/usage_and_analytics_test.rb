# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# GET /api/usage on the engine (#395).
class UsageTest < ActionDispatch::IntegrationTest
  def teardown
    ActionAgent.usage_resolver = nil
  end

  test "a bare mount reports unlimited usage instead of 404" do
    get "/activeagents/api/usage"

    assert_response :success
    usage = JSON.parse(response.body)["usage"]
    assert usage["unlimited"]
    assert usage["can_run"]
    assert_nil usage["runs_limit"]
  end

  test "a host that meters usage answers through its resolver" do
    ActionAgent.usage_resolver = ->(_owner) { { runs_used: 3, runs_limit: 10, runs_remaining: 7, can_run: true, plan: "pro" } }

    get "/activeagents/api/usage"

    assert_response :success
    usage = JSON.parse(response.body)["usage"]
    assert_equal 3, usage["runs_used"]
    assert_equal "pro", usage["plan"]
  end

  test "a resolver that raises degrades to unlimited" do
    ActionAgent.usage_resolver = ->(_owner) { raise "billing is down" }

    get "/activeagents/api/usage"

    assert_response :success
    assert JSON.parse(response.body).dig("usage", "unlimited")
  end
end

# Daily charts are zero-filled across the window (#385) and per-agent
# analytics count telemetry-observed executions (#376).
class AnalyticsTest < ActionDispatch::IntegrationTest
  TelemetryTraceTest.ensure_table!

  def setup
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
  end

  def create_run(created_at:, **attributes)
    @agent.agent_runs.create!({ input_prompt: "hi", status: :complete, total_tokens: 5, duration_ms: 100, created_at: created_at }.merge(attributes))
  end

  def report_trace(status: "OK", tokens: { "input" => 10, "output" => 5, "thinking" => 0 }, error: nil)
    trace = ActionAgent::TelemetryTrace.create_from_payload({
      "trace_id" => SecureRandom.hex(16),
      "service_name" => "customer-app",
      "timestamp" => Time.current.iso8601(6),
      "spans" => [
        {
          "span_id" => "r1", "parent_span_id" => nil, "name" => "SupportAgent.respond",
          "type" => "root", "duration_ms" => 300.0, "status" => status,
          "attributes" => { "agent.class" => "SupportAgent", "agent.action" => "respond" }.merge(error ? { "error.message" => error } : {}),
          "tokens" => tokens
        }
      ]
    })
    trace.update!(agent_id: @agent.id)
    trace
  end

  test "the dashboard-wide daily series covers every day of the window" do
    create_run(created_at: 3.days.ago)

    get "/activeagents/api/analytics", params: { days: 7 }

    assert_response :success
    charts = JSON.parse(response.body)["charts"]
    assert_equal 8, charts["runs_by_day"].size, "seven days ago through today"
    assert_equal 8, charts["tokens_by_day"].size
    assert_equal [ 0, 0, 0, 0, 1, 0, 0, 0 ], charts["runs_by_day"].map { |day| day["count"] }
    assert_equal 7.days.ago.to_date.to_s, charts["runs_by_day"].first["date"]
    assert_equal Date.current.to_s, charts["runs_by_day"].last["date"]
  end

  test "per-agent daily series covers every day of the window" do
    create_run(created_at: 2.days.ago)

    get "/activeagents/api/agents/#{@agent.id}/analytics", params: { days: 3 }

    assert_response :success
    days = JSON.parse(response.body)["runs_by_day"]
    assert_equal 4, days.size
    assert_equal [ 0, 1, 0, 0 ], days.map { |day| day["count"] }
  end

  test "per-agent analytics count telemetry-observed executions alongside dashboard runs" do
    create_run(created_at: 1.day.ago, total_tokens: 5, duration_ms: 100)
    report_trace
    report_trace(status: "ERROR", error: "rate limited")

    get "/activeagents/api/agents/#{@agent.id}/analytics", params: { days: 7 }

    assert_response :success
    body = JSON.parse(response.body)
    summary = body["summary"]
    assert_equal 3, summary["total_runs"]
    assert_equal 2, summary["completed_runs"]
    assert_equal 1, summary["failed_runs"]
    assert_equal 66.7, summary["success_rate"]
    assert_equal 35, summary["total_tokens"], "5 dashboard tokens plus 15 per reported trace"
    assert_equal ((100 + 300 + 300) / 3.0).round, summary["avg_duration_ms"]

    assert_equal 2, body["runs_by_day"].last["count"], "both reported traces landed today"
    assert_equal({ "complete" => 2, "failed" => 1 }, body["status_breakdown"])

    error = body["recent_errors"].find { |row| row["source"] == "reported" }
    assert_equal "rate limited", error["error"]
  end

  test "a telemetry-only agent no longer reports all-zero metrics" do
    report_trace

    get "/activeagents/api/agents/#{@agent.id}/analytics"

    assert_response :success
    summary = JSON.parse(response.body)["summary"]
    assert_equal 1, summary["total_runs"]
    assert_equal 100.0, summary["success_rate"]
    assert_equal 15, summary["total_tokens"]
  end
end
