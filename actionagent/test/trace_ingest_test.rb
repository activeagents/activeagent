# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# The ingest endpoint keeps every trace it is sent and honours the host's
# :trace_ingest quota (#383).
class TraceIngestTest < ActionDispatch::IntegrationTest
  TelemetryTraceTest.ensure_table!

  def setup
    ActionAgent::TelemetryTrace.delete_all
  end

  def teardown
    ActionAgent.quota_checker = nil
  end

  def trace(index)
    {
      "trace_id" => "batch-#{index}-#{SecureRandom.hex(6)}",
      "service_name" => "batch-probe",
      "timestamp" => Time.current.iso8601(6),
      "spans" => [
        {
          "span_id" => "s#{index}", "parent_span_id" => nil, "name" => "ProbeAgent.run",
          "type" => "root", "duration_ms" => 1.0, "status" => "OK",
          "attributes" => { "agent.class" => "ProbeAgent", "agent.action" => "run" }
        }
      ]
    }
  end

  test "every trace in a batch larger than a hundred is stored" do
    post "/activeagents/api/traces", params: { traces: 105.times.map { |i| trace(i) } }, as: :json

    assert_response :accepted
    assert_equal 105, ActionAgent::TelemetryTrace.for_service("batch-probe").count,
      "traces beyond the hundredth were dropped while the client was told 202"
  end

  test "the host's trace_ingest quota is enforced with 429 and nothing is stored" do
    ActionAgent.quota_checker = ->(_owner, kind) { "Ingest allowance used up" if kind == :trace_ingest }

    post "/activeagents/api/traces", params: { traces: [ trace(1) ] }, as: :json

    assert_response :too_many_requests
    body = JSON.parse(response.body)
    assert_equal "Ingest allowance used up", body["message"]
    assert_equal 0, ActionAgent::TelemetryTrace.count
  end

  test "a checker that only limits executions does not block ingest" do
    ActionAgent.quota_checker = ->(_owner, kind) { "Out of runs" if kind == :execution }

    post "/activeagents/api/traces", params: { traces: [ trace(1) ] }, as: :json

    assert_response :accepted
    assert_equal 1, ActionAgent::TelemetryTrace.count
  end
end
