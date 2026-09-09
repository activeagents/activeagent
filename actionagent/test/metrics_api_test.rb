# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# GET <mount>/api/metrics — the APM keys behind the Metrics view (series,
# totals, deltas, rails, markers), through the engine mounted in the dummy
# app at /activeagents. The dummy app is single-tenant on SQLite, so this
# exercises MetricsReport over TelemetryTrace's Ruby span-reading path; the
# PostgreSQL jsonb path has the same contract but is not covered here.
#
# Time is frozen at 12:07 UTC so bucket boundaries are known: with 15-minute
# buckets the live bucket starts at 12:00 and `ago(k)` lands k buckets back.
class MetricsApiTest < ActionDispatch::IntegrationTest
  TelemetryTraceTest.ensure_table!

  NOW = Time.utc(2026, 9, 8, 12, 7, 0)
  BUCKET = 900

  def setup
    ActionAgent::AgentVersion.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::TelemetryTrace.delete_all
    travel_to NOW
  end

  def teardown
    travel_back
  end

  def metrics(**params)
    get "/activeagents/api/metrics", params: params
    assert_response :success, response.body
    JSON.parse(response.body)
  end

  # The start of the bucket +count+ buckets before the live one.
  def ago(count, seconds: BUCKET)
    NOW - (count * seconds)
  end

  def create_agent(name: "Support", **attributes)
    ActionAgent::Agent.create!({ name: name, provider: "openai", model: "gpt-4o-mini" }.merge(attributes))
  end

  # A trace as the ingest endpoint would have stored it: a root span, an
  # llm span carrying the model (unless model: nil) and one span per tool.
  def create_trace(at:, agent: "SupportAgent", action: "respond", status: "OK", duration: 300, error: nil,
                   tokens: [ 10, 5 ], model: "gpt-4o-mini", provider: "openai", tools: [], environment: "production")
    spans = [
      {
        "span_id" => "r1", "parent_span_id" => nil, "name" => "#{agent}.#{action}", "type" => "root",
        "duration_ms" => duration, "status" => status,
        "attributes" => { "agent.class" => agent, "agent.action" => action, "error.message" => error }.compact
      }
    ]
    if model
      spans << {
        "span_id" => "l1", "parent_span_id" => "r1", "name" => "llm.generate", "type" => "llm",
        "duration_ms" => duration, "status" => "OK",
        "attributes" => { "llm.model" => model, "llm.provider" => provider }
      }
    end
    tools.each_with_index do |tool, index|
      spans << {
        "span_id" => "t#{index}", "parent_span_id" => "r1", "name" => "tool.#{tool[:name]}", "type" => "tool",
        "duration_ms" => tool.fetch(:duration_ms, 100), "status" => tool.fetch(:status, "OK"),
        "attributes" => { "tool.name" => tool[:name] }
      }
    end

    ActionAgent::TelemetryTrace.create!(
      trace_id: SecureRandom.hex(16),
      service_name: "dummy",
      environment: environment,
      timestamp: at,
      spans: spans,
      total_duration_ms: duration,
      total_input_tokens: tokens[0],
      total_output_tokens: tokens[1],
      status: status,
      agent_class: agent,
      agent_action: action,
      error_message: error
    )
  end

  # --- ranges and buckets -------------------------------------------------

  test "each range has its bucket size and count, zero-filled and aligned to now" do
    { "1h" => [ 60, 60, 60 ], "24h" => [ 900, 96, 1440 ], "7d" => [ 7200, 84, 10_080 ] }
      .each do |range, (seconds, count, minutes)|
      body = metrics(range: range)

      assert_equal range, body["range"]
      assert_equal seconds, body["bucket_seconds"]
      assert_equal minutes, body["window_minutes"]
      assert_nil body["agent"]
      assert_equal count, body["series"].size

      assert body["series"].all? { |bucket| bucket["requests"].zero? }, "#{range} buckets must be zero-filled"
      assert body["series"].all? { |bucket| bucket["p50_ms"].nil? }, "an empty bucket has no percentiles"
      assert body["series"].all? { |bucket| bucket["errors_by_type"].keys == ActionAgent::MetricsReport::ERROR_TYPES }

      last_start = Time.at((NOW.to_i / seconds) * seconds).utc
      assert_equal last_start.iso8601, body["series"].last["ts"], "the live bucket contains now"
      assert_equal (last_start - ((count - 1) * seconds)).iso8601, body["series"].first["ts"]

      assert_equal 0, body.dig("totals", "requests")
      assert_equal ActionAgent::MetricsReport::ERROR_TYPES.map { |type| { "type" => type, "count" => 0 } },
        body["errors_by_type"]
    end
  end

  test "the default range is 24h" do
    body = metrics

    assert_equal "24h", body["range"]
    assert_equal 96, body["series"].size
    assert_equal 24, body["window_hours"]
  end

  test "hours without a range is a custom window bucketed to about 96 points" do
    body = metrics(hours: 48)

    assert_equal "custom", body["range"]
    assert_equal 1800, body["bucket_seconds"]
    assert_equal 96, body["series"].size
    assert_equal 48 * 60, body["window_minutes"]
    assert_equal 48, body["window_hours"]
    assert_equal 48, body["hourly_requests"].size
  end

  test "a custom window takes the smallest bucket size that keeps it within the target" do
    # 48h: 1800s x 96 exactly. 193h: 7200s would need 97 buckets, so 10800s x 65.
    assert_equal [ "custom", 1800, 96, 48 ], ActionAgent::MetricsReport.resolve_range(nil, "48")
    assert_equal [ "custom", 10_800, 65, 193 ], ActionAgent::MetricsReport.resolve_range(nil, "193")
    assert_equal [ "custom", 60, 60, 1 ], ActionAgent::MetricsReport.resolve_range(nil, "1")
    assert_equal [ "custom", 43_200, 60, 720 ], ActionAgent::MetricsReport.resolve_range(nil, "9999"), "clamped to 30 days"

    body = metrics(hours: 193)
    assert_equal 65, body["series"].size
    assert_operator body["series"].size, :<=, ActionAgent::MetricsReport::TARGET_BUCKETS
  end

  test "a named range wins over hours and sets the legacy window to match" do
    body = metrics(range: "1h", hours: 48)

    assert_equal "1h", body["range"]
    assert_equal 1, body["window_hours"]
    assert_equal 1, body["hourly_requests"].size
  end

  test "requests stack by agent inside each bucket" do
    2.times { create_trace(at: ago(3), agent: "SupportAgent") }
    create_trace(at: ago(3), agent: "BillingAgent")
    create_trace(at: ago(1), agent: "BillingAgent")

    body = metrics
    bucket = body["series"][-4]

    assert_equal 3, bucket["requests"]
    assert_equal({ "SupportAgent" => 2, "BillingAgent" => 1 }, bucket["requests_by_agent"])
    assert_equal({ "BillingAgent" => 1 }, body["series"][-2]["requests_by_agent"])
    assert_equal 4, body["series"].sum { |b| b["requests"] }
    assert_equal 4, body.dig("totals", "requests")

    agents = body["agents"]
    assert_equal %w[BillingAgent SupportAgent], agents.map { |a| a["name"] }
    assert_equal [ 2, 2 ], agents.map { |a| a["requests"] }
    assert_equal [ 50.0, 50.0 ], agents.map { |a| a["share_pct"] }
  end

  # --- percentiles ----------------------------------------------------------

  test "latency percentiles are nearest-rank over trace durations" do
    [ 100, 200, 300, 400, 1000 ].each { |ms| create_trace(at: ago(2), duration: ms) }
    create_trace(at: ago(2), duration: nil)

    body = metrics
    bucket = body["series"][-3]

    assert_equal 6, bucket["requests"]
    assert_equal 300, bucket["p50_ms"]
    assert_equal 1000, bucket["p95_ms"]
    assert_equal 1000, bucket["p99_ms"]
    assert_nil body["series"][-2]["p50_ms"]

    assert_equal 300, body.dig("totals", "p50_ms")
    assert_equal 1000, body.dig("totals", "p95_ms")
    assert_equal 1000, body.dig("totals", "p99_ms")
    assert_equal 1000, body["agents"].first["p95_ms"]
  end

  test "percentile is nearest rank" do
    assert_nil ActionAgent::MetricsReport.percentile([], 50)
    assert_equal 1, ActionAgent::MetricsReport.percentile([ 1 ], 99)
    assert_equal 2, ActionAgent::MetricsReport.percentile([ 1, 2, 3, 4 ], 50)
    assert_equal 4, ActionAgent::MetricsReport.percentile([ 1, 2, 3, 4 ], 95)
    assert_equal 95, ActionAgent::MetricsReport.percentile((1..100).to_a, 95)
    assert_equal 99, ActionAgent::MetricsReport.percentile((1..100).to_a, 99)
  end

  # --- error classification -------------------------------------------------

  test "classifies 429s, rate limits and quota errors" do
    assert_equal "429 rate limit", ActionAgent::MetricsReport.classify_error("HTTP 429 Too Many Requests")
    assert_equal "429 rate limit", ActionAgent::MetricsReport.classify_error("Rate-limit exceeded, retry later")
    assert_equal "429 rate limit", ActionAgent::MetricsReport.classify_error("You exceeded your current quota")
  end

  test "classifies timeouts" do
    assert_equal "timeout", ActionAgent::MetricsReport.classify_error("Net::ReadTimeout with #<TCPSocket>")
    assert_equal "timeout", ActionAgent::MetricsReport.classify_error("Request timed out after 30s")
    assert_equal "timeout", ActionAgent::MetricsReport.classify_error("context deadline exceeded")
  end

  test "classifies provider 5xx errors" do
    assert_equal "provider 5xx", ActionAgent::MetricsReport.classify_error("502 Bad Gateway")
    assert_equal "provider 5xx", ActionAgent::MetricsReport.classify_error("overloaded_error: Overloaded")
    assert_equal "provider 5xx", ActionAgent::MetricsReport.classify_error("upstream connect error")
  end

  test "classifies anything else as other" do
    assert_equal "other", ActionAgent::MetricsReport.classify_error("undefined method `chat' for nil")
    assert_equal "other", ActionAgent::MetricsReport.classify_error(nil)
    assert_equal "other", ActionAgent::MetricsReport.classify_error("")
  end

  test "an errored tool span makes it a tool error whatever the message says" do
    assert_equal "tool error", ActionAgent::MetricsReport.classify_error("HTTP 429 Too Many Requests", tool_errors: 1)
    assert_equal "tool error", ActionAgent::MetricsReport.classify_error(nil, tool_errors: 2)
    assert_equal "429 rate limit", ActionAgent::MetricsReport.classify_error("HTTP 429", tool_errors: 0)
  end

  test "errors are classified end to end, in ERROR_TYPES order with zero counts" do
    create_trace(at: ago(2), status: "ERROR", error: "HTTP 429 Too Many Requests")
    create_trace(at: ago(2), status: "ERROR", error: "Request timed out")
    create_trace(at: ago(2), status: "ERROR", error: "HTTP 429", tools: [ { name: "fetch", status: "ERROR" } ])
    create_trace(at: ago(2), status: "ERROR", error: "503 Service Unavailable")
    create_trace(at: ago(2), status: "ERROR", error: "boom")
    create_trace(at: ago(2), status: "OK")
    create_trace(at: ago(1), status: "ERROR", error: "HTTP 429")

    body = metrics

    assert_equal 6, body.dig("totals", "errors")
    assert_equal 85.71, body.dig("totals", "error_rate"), "6 of 7 traces"
    assert_equal [
      { "type" => "429 rate limit", "count" => 2 },
      { "type" => "timeout", "count" => 1 },
      { "type" => "tool error", "count" => 1 },
      { "type" => "provider 5xx", "count" => 1 },
      { "type" => "other", "count" => 1 }
    ], body["errors_by_type"]

    bucket = body["series"][-3]
    assert_equal 5, bucket["errors"]
    assert_equal(
      { "429 rate limit" => 1, "timeout" => 1, "tool error" => 1, "provider 5xx" => 1, "other" => 1 },
      bucket["errors_by_type"]
    )
    assert_equal({ "429 rate limit" => 1, "timeout" => 0, "tool error" => 0, "provider 5xx" => 0, "other" => 0 },
      body["series"][-2]["errors_by_type"])
  end

  # --- agent filter ---------------------------------------------------------

  test "the agent filter narrows the series, rails, totals and the legacy keys" do
    create_trace(at: ago(2), agent: "SupportAgent", action: "respond", duration: 500, status: "ERROR", error: "boom")
    create_trace(at: ago(2), agent: "SupportAgent", action: "triage", duration: 200)
    create_trace(at: ago(1), agent: "SupportAgent", action: "respond", duration: 400, model: "gpt-4o")
    create_trace(at: ago(1), agent: "BillingAgent", action: "invoice", duration: 900, model: "claude-haiku-4")
    create_trace(at: ago(3), agent: "BillingAgent", action: "invoice", duration: 900, model: "claude-haiku-4",
      tools: [ { name: "stripe" } ])

    body = metrics(agent: "SupportAgent")

    assert_equal "SupportAgent", body["agent"]
    assert_equal 3, body.dig("totals", "requests")
    assert_equal 1, body.dig("totals", "errors")
    assert_equal 0, body.dig("totals", "tool_calls")
    assert_equal 3, body["series"].sum { |b| b["requests"] }
    assert_equal({ "SupportAgent" => 2 }, body["series"][-3]["requests_by_agent"])
    assert_equal [ "SupportAgent" ], body["agents"].map { |a| a["name"] }
    assert_equal 100.0, body["agents"].first["share_pct"]
    assert_equal %w[gpt-4o-mini gpt-4o], body["models"].map { |m| m["model"] }
    assert_equal %w[SupportAgent#respond SupportAgent#triage], body["actions"].map { |a| a["name"] }
    assert_equal [], body["tools"]
    # Legacy keys follow the filter too, so tiles and charts agree.
    assert_equal 3, body.dig("summary", "total_requests")
    assert_equal [ "SupportAgent" ], body["by_agent"].map { |a| a["name"] }
    assert_equal 3, body["hourly_requests"].sum { |h| h["count"] }

    unfiltered = metrics
    assert_nil unfiltered["agent"]
    assert_equal 5, unfiltered.dig("totals", "requests")
    assert_equal %w[BillingAgent SupportAgent], unfiltered["agents"].map { |a| a["name"] }.sort
    assert_equal 5, unfiltered.dig("summary", "total_requests")
  end

  # --- deltas ---------------------------------------------------------------

  test "deltas compare the window with the period of the same length before it" do
    4.times do |i|
      create_trace(at: ago(1), duration: 400, tokens: [ 50, 50 ], status: i.zero? ? "ERROR" : "OK", error: i.zero? ? "boom" : nil)
    end
    2.times { create_trace(at: NOW - 30.hours, duration: 200, tokens: [ 25, 25 ]) }

    deltas = metrics["deltas"]

    assert_equal 100.0, deltas["requests_pct"]
    assert_equal 100.0, deltas["p50_pct"]
    assert_equal 25.0, deltas["error_rate_pt"]
    assert_equal 300.0, deltas["tokens_pct"]
    assert_equal 300.0, deltas["cost_pct"]
  end

  test "deltas are null without a previous period to compare against" do
    create_trace(at: ago(1), duration: 400, tokens: [ 50, 50 ])
    create_trace(at: NOW - 3.days, duration: 400, tokens: [ 50, 50 ])

    deltas = metrics["deltas"]

    assert_equal %w[requests_pct p50_pct error_rate_pt tokens_pct cost_pct], deltas.keys
    assert deltas.values.all?(&:nil?), deltas.inspect
  end

  # --- totals ---------------------------------------------------------------

  test "totals cover requests, throughput, tokens and cost for the window" do
    create_trace(at: ago(1), tokens: [ 100, 50 ], model: "gpt-4o-mini")
    create_trace(at: ago(5), tokens: [ 200, 100 ], model: "gpt-4o-mini")

    totals = metrics["totals"]

    assert_equal 2, totals["requests"]
    assert_in_delta 2.0 / 1440, totals["requests_per_minute"], 0.01
    assert_equal 300, totals["tokens_in"]
    assert_equal 150, totals["tokens_out"]
    assert_equal 450, totals["tokens"]
    expected_cost = ActionAgent::ModelPricing.estimate(model: "gpt-4o-mini", input_tokens: 300, output_tokens: 150)
    assert_in_delta expected_cost, totals["cost"], 0.0001
    assert_in_delta expected_cost / 2, totals["cost_per_request"], 0.000001
    assert_equal 0.0, totals["error_rate"]
    assert_equal 0.0, totals["tool_error_rate"]
  end

  # --- rails ----------------------------------------------------------------

  test "the tools rail comes from tool spans" do
    create_trace(at: ago(2), tools: [
      { name: "web_search", duration_ms: 100 },
      { name: "web_search", duration_ms: 300, status: "ERROR" },
      { name: "fetch", duration_ms: 50 }
    ])
    create_trace(at: ago(1), tools: [ { name: "web_search", duration_ms: 200 } ])

    body = metrics

    assert_equal [
      { "name" => "web_search", "calls" => 3, "avg_ms" => 200, "error_rate" => 33.33 },
      { "name" => "fetch", "calls" => 1, "avg_ms" => 50, "error_rate" => 0.0 }
    ], body["tools"]
    assert_equal 4, body.dig("totals", "tool_calls")
    assert_equal 1, body.dig("totals", "tool_errors")
    assert_equal 25.0, body.dig("totals", "tool_error_rate")
    assert_equal 3, body["series"][-3]["tool_calls"]
    assert_equal 1, body["series"][-3]["tool_errors"]
  end

  test "a tool span without a tool.name attribute is named from its span name" do
    trace = create_trace(at: ago(1))
    trace.update!(spans: trace.spans + [
      { "span_id" => "t9", "parent_span_id" => "r1", "name" => "tool.glossary_lookup", "type" => "tool",
        "duration_ms" => 40, "status" => "OK", "attributes" => {} }
    ])

    assert_equal [ "glossary_lookup" ], metrics["tools"].map { |t| t["name"] }
  end

  test "the models rail ranks models by tokens with unknown for traces without an llm span" do
    2.times { create_trace(at: ago(1), model: "gpt-4o-mini", provider: "openai", tokens: [ 100, 50 ]) }
    create_trace(at: ago(2), model: "claude-sonnet-4", provider: "anthropic", tokens: [ 400, 100 ])
    create_trace(at: ago(2), model: nil, tokens: [ 10, 0 ])

    models = metrics["models"]

    assert_equal %w[claude-sonnet-4 gpt-4o-mini unknown], models.map { |m| m["model"] }
    assert_equal [ "anthropic", "openai", nil ], models.map { |m| m["provider"] }
    assert_equal [ 1, 2, 1 ], models.map { |m| m["requests"] }
    assert_equal [ 500, 300, 10 ], models.map { |m| m["tokens"] }
    assert_equal [ 61.73, 37.04, 1.23 ], models.map { |m| m["share_pct"] }
    assert_in_delta ActionAgent::ModelPricing.estimate(model: "claude-sonnet-4", input_tokens: 400, output_tokens: 100),
      models.first["cost"], 0.0001
  end

  test "the models rail keeps the top eight" do
    10.times { |i| create_trace(at: ago(1), model: "model-#{i}", tokens: [ 10 * (i + 1), 0 ]) }

    models = metrics["models"]

    assert_equal 8, models.size
    assert_equal "model-9", models.first["model"]
  end

  test "the actions rail ranks the slowest actions by p95" do
    create_trace(at: ago(1), agent: "ResearchAgent", action: "research", duration: 3800)
    create_trace(at: ago(1), agent: "TranslationAgent", action: "translate", duration: 1900)
    create_trace(at: ago(1), agent: "TranslationAgent", action: "translate", duration: 100)
    create_trace(at: ago(1), agent: "TranslationAgent", action: "export", duration: 2400)
    create_trace(at: ago(1), agent: "DocumentationAgent", action: "sync", duration: nil)

    actions = metrics["actions"]

    assert_equal [
      { "name" => "ResearchAgent#research", "agent" => "ResearchAgent", "requests" => 1, "p95_ms" => 3800 },
      { "name" => "TranslationAgent#export", "agent" => "TranslationAgent", "requests" => 1, "p95_ms" => 2400 },
      { "name" => "TranslationAgent#translate", "agent" => "TranslationAgent", "requests" => 2, "p95_ms" => 1900 }
    ], actions
  end

  test "the agents rail carries error rate, cost and tokens per agent" do
    create_trace(at: ago(1), agent: "SupportAgent", tokens: [ 100, 50 ], status: "ERROR", error: "boom")
    create_trace(at: ago(1), agent: "SupportAgent", tokens: [ 100, 50 ])
    create_trace(at: ago(1), agent: "SupportAgent", tokens: [ 100, 50 ])
    create_trace(at: ago(1), agent: "BillingAgent", tokens: [ 10, 10 ])

    agents = metrics["agents"]

    assert_equal %w[SupportAgent BillingAgent], agents.map { |a| a["name"] }
    support = agents.first
    assert_equal 3, support["requests"]
    assert_equal 75.0, support["share_pct"]
    assert_equal 33.33, support["error_rate"]
    assert_equal 450, support["tokens"]
    assert_in_delta ActionAgent::ModelPricing.estimate(model: "gpt-4o-mini", input_tokens: 300, output_tokens: 150),
      support["cost"], 0.0001
  end

  test "environment is the one most of the window's traces report" do
    assert_nil metrics["environment"]

    create_trace(at: ago(1), environment: "staging")
    create_trace(at: ago(1), environment: "production")
    create_trace(at: ago(2), environment: "production")
    create_trace(at: ago(2), environment: nil)

    assert_equal "production", metrics["environment"]
  end

  # --- markers --------------------------------------------------------------

  test "a deploy marker records each agent version created inside the window" do
    agent = travel_to(NOW - 2.days) { create_agent(name: "Support") }
    agent.update!(instructions: "Be brief.")
    agent.update!(tools: [ "fetch" ])
    travel_to(NOW - 2.days) { create_agent(name: "Billing") }

    markers = metrics["markers"]

    assert_equal [
      { "kind" => "deploy", "ts" => NOW.iso8601, "label" => "instructions v2 · Support", "agent" => "Support" },
      { "kind" => "deploy", "ts" => NOW.iso8601, "label" => "v3 · Support", "agent" => "Support" }
    ], markers
  end

  test "deploy markers read the window's versions and their predecessors in two queries" do
    # v1 of each agent sits outside the window, so v2's predecessor must be
    # fetched; v3's predecessor (v2) is already among the window's versions.
    agents = 3.times.map { |i| travel_to(NOW - 2.days) { create_agent(name: "Agent #{i}") } }
    agents.each do |agent|
      agent.update!(instructions: "Be brief.")
      agent.update!(tools: [ "fetch" ])
    end

    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].include?("active_agent_agent_versions")
    end
    markers = ActionAgent::MetricsReport.new(traces: ActionAgent::TelemetryTrace.all, agents: ActionAgent::Agent.all).markers
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_equal [
      "instructions v2 · Agent 0", "v3 · Agent 0",
      "instructions v2 · Agent 1", "v3 · Agent 1",
      "instructions v2 · Agent 2", "v3 · Agent 2"
    ], markers.map { |marker| marker[:label] }
    assert_equal 2, queries.size, queries.join("\n")
  end

  test "deploy markers follow the agent filter" do
    create_agent(name: "Support")
    create_agent(name: "Billing", instructions: "Bill things.")

    assert_equal [ "v1 · Support", "instructions v1 · Billing" ], metrics["markers"].map { |m| m["label"] }
    assert_equal [ "instructions v1 · Billing" ], metrics(agent: "BillingAgent")["markers"].map { |m| m["label"] }
    assert_equal [], metrics(agent: "ResearchAgent")["markers"]
  end

  test "an incident marker flags the bucket with the error spike" do
    6.times { create_trace(at: ago(5), agent: "SupportAgent", status: "ERROR", error: "HTTP 429 Too Many Requests") }
    create_trace(at: ago(5), agent: "BillingAgent", status: "ERROR", error: "Request timed out")
    30.times { |i| create_trace(at: ago(10 + i), status: "OK") }

    markers = metrics["markers"]

    assert_equal 1, markers.size
    assert_equal({
      "kind" => "incident",
      "ts" => (NOW - 7.minutes - (5 * 15).minutes).iso8601,
      "label" => "429 rate limit spike",
      "agent" => "SupportAgent"
    }, markers.first)
  end

  test "no incident marker below five errors or without a spike over the window rate" do
    4.times { create_trace(at: ago(5), status: "ERROR", error: "HTTP 429") }
    30.times { |i| create_trace(at: ago(10 + i), status: "OK") }
    assert_equal [], metrics["markers"], "four errors are not an incident"

    ActionAgent::TelemetryTrace.delete_all
    # Errors everywhere at the same rate: the busiest bucket is no spike.
    10.times { |i| 5.times { create_trace(at: ago(i + 1), status: "ERROR", error: "HTTP 429") } }
    assert_equal [], metrics["markers"], "a flat error rate is not an incident"
  end

  # --- legacy keys ----------------------------------------------------------

  test "the legacy keys keep their shape and definitions" do
    create_trace(at: ago(1), tokens: [ 10, 5 ])

    body = metrics

    assert_equal %w[summary hourly_requests by_agent window_hours sorts sort], body.keys.first(6)
    assert_equal 1, body.dig("summary", "total_requests")
    assert_equal 15, body.dig("summary", "tokens_used")
    assert_equal 24, body["window_hours"]
    assert_equal 24, body["hourly_requests"].size
    assert_equal 1, body["hourly_requests"].sum { |hour| hour["count"] }
    assert body["hourly_requests"].last["active"]
    assert_equal [ "SupportAgent" ], body["by_agent"].map { |a| a["name"] }
    assert_equal "popular", body["sort"]
    assert_equal ActionAgent::Api::MetricsController::AGENT_SORTS, body["sorts"]

    assert_equal "cost", metrics(sort: "cost")["sort"]
    assert_equal "popular", metrics(sort: "bogus")["sort"]
  end
end
