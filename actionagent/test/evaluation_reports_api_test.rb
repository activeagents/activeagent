# frozen_string_literal: true

require "test_helper"

# A tenant for the multi-tenant cases. The dummy app configures no account
# model, so the table is created here, the way TelemetryTraceTest creates the
# trace table.
class ReportTestAccount < ActiveRecord::Base
  belongs_to :owner, class_name: "User", optional: true

  # The trace ingest usage hook a host may define, counted per class.
  cattr_accessor :telemetry_requests, default: 0

  def increment_telemetry_usage!
    self.class.telemetry_requests += 1
  end

  def self.ensure_table!
    return if connection.table_exists?(:report_test_accounts)

    connection.create_table :report_test_accounts do |t|
      t.string :name
      t.string :telemetry_api_key
      t.bigint :owner_id
    end
  end
end
ReportTestAccount.ensure_table!

# A trace model whose instances carry an account, as a multi-tenant host's
# does, for the trace_owner_resolver case. The dummy's own trace model was
# loaded single-tenant and has no account association.
class ReportTenantTrace < ActionAgent::TelemetryTrace
  attr_accessor :account
end

# The collector at <mount>/api/evaluation_reports: what
# ActiveAgent::Evals::Publisher delivers, and how the engine stores it.
class EvaluationReportsApiTest < ActionDispatch::IntegrationTest
  Evals = ActiveAgent::Evals
  ENDPOINT = "/activeagents/api/evaluation_reports"

  def setup
    ActionAgent::Agent.delete_all
  end

  def teardown
    ActionAgent.ingest_api_key = nil
    ActionAgent.multi_tenant = false
    ActionAgent.account_class = nil
    ActionAgent.user_class = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.trace_owner_resolver = nil
    ActionAgent.trace_model_class = nil
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
  end

  # A report as ActiveAgent::Evals::Publisher sends it: two scenarios under two
  # models, the second model failing one of them.
  def envelope(run_id: "run-#{SecureRandom.hex(4)}", answer: "Order 1234 shipped on Monday.")
    { "version" => 1, "run_id" => run_id, "source" => "support-app", "agent_name" => "SupportBot", "suite" => "orders",
      "report" => report(run_id: run_id, answer: answer).to_h }
  end

  def report(run_id:, answer: "Order 1234 shipped on Monday.", judge_label: "gpt-5-mini")
    specs = [
      Evals::ModelSpec.new(label: "gpt-5-mini", provider: "openai", model: "gpt-5-mini"),
      Evals::ModelSpec.new(label: "openrouter/anthropic/claude-sonnet-5", provider: "openrouter", model: "anthropic/claude-sonnet-5")
    ]
    scenarios = [
      Evals::Scenario.from_hash({ "key" => "status_1", "group" => "status", "prompt" => "Where is order 1234?" }),
      Evals::Scenario.from_hash({ "key" => "refund_1", "group" => "refunds", "prompt" => "Can I get a refund for order 1234?" })
    ]
    results = scenarios.product(specs).each_with_index.map do |(scenario, spec), index|
      failing = scenario.key == "refund_1" && spec.provider == "openrouter"
      Evals::Result.new(
        scenario: scenario,
        spec: spec,
        replay: Evals::Replay.new(
          answer: failing ? "I don't have access to refunds." : answer,
          tool_calls: [ { "name" => "lookup_order", "arguments" => { "order_id" => "1234" } } ],
          duration_ms: 1200, input_tokens: 100, output_tokens: 20, cost: 0.0004,
          metadata: { "run_id" => run_id, "result_id" => "result-#{index}", "trace_id" => "trace#{index}", "judge_trace_ids" => [ "judge#{index}" ] }
        ),
        scores: { "response_present" => 1.0 },
        score: failing ? 0.2 : 1.0,
        status: failing ? "failed" : "passed",
        diagnosis: failing ? { "fault" => "missing_capability", "summary" => "Declined", "recommendation" => "Add a refund tool" } : nil
      )
    end

    Evals::Report.new(
      results: results, models: specs, judge_label: judge_label,
      metadata: { "run_id" => run_id, "suite" => "orders", "scope" => "eu", "role" => "support" }
    )
  end

  def publish(payload, token: nil, content_type: "application/json")
    headers = { "Content-Type" => content_type }
    headers["Authorization"] = "Bearer #{token}" if token
    post ENDPOINT, params: payload.is_a?(String) ? payload : payload.to_json, headers: headers
  end

  def json_response
    JSON.parse(response.body)
  end

  def use_tenants!
    ActionAgent.multi_tenant = true
    ActionAgent.account_class = "ReportTestAccount"
  end

  def create_tenant(name, owner: nil)
    ReportTestAccount.create!(name: name, telemetry_api_key: "key-#{SecureRandom.hex(8)}", owner: owner)
  end

  # A request body that counts the bytes read from it.
  class CountingInput < StringIO
    attr_reader :bytes_read

    def read(*args)
      super.tap { |chunk| @bytes_read = (@bytes_read || 0) + chunk.to_s.bytesize }
    end
  end

  # Posts +body+ through the whole app with no Content-Length, as a chunked
  # request arrives. Returns the status and how many bytes the app read.
  def post_chunked(body)
    input = CountingInput.new(body.b)
    env = Rack::MockRequest.env_for(ENDPOINT, method: "POST", "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost")
    env.delete("CONTENT_LENGTH")
    env["HTTP_TRANSFER_ENCODING"] = "chunked"
    env["rack.input"] = input
    [ Rails.application.call(env).first, input.bytes_read.to_i ]
  end

  def create_user(name)
    User.create!(name: name, email: "#{name.parameterize}-#{SecureRandom.hex(3)}@example.com", age: 30)
  end

  # --- authentication ---------------------------------------------------------

  test "rejects a request without the configured ingest key" do
    ActionAgent.ingest_api_key = "install-key"

    publish(envelope)
    assert_response :unauthorized

    publish(envelope, token: "wrong")
    assert_response :unauthorized
    assert_equal 0, ActionAgent::EvaluationRun.count
  end

  test "accepts the configured ingest key" do
    ActionAgent.ingest_api_key = "install-key"

    publish(envelope, token: "install-key")

    assert_response :created
  end

  test "rejects a multi-tenant request without a key or with an unknown one" do
    use_tenants!

    publish(envelope)
    assert_response :unauthorized
    assert_equal "Missing Authorization header", json_response["error"]

    publish(envelope, token: "wrong")
    assert_response :unauthorized
    assert_equal "Invalid API key", json_response["error"]
  end

  # --- storing ----------------------------------------------------------------

  test "stores the report as the dashboard's own evaluation rows and returns the publisher's receipt" do
    payload = envelope
    publish(payload)

    assert_response :created
    run = ActionAgent::EvaluationRun.find(json_response["id"])
    assert_equal payload["run_id"], json_response["run_id"], "the receipt echoes the run_id"
    assert_equal "complete", json_response["status"]
    assert_equal run.evaluation_id, json_response["evaluation_id"]
    assert_equal false, json_response["duplicate"]
    assert_equal "/activeagents/evaluations/#{run.evaluation_id}/runs/#{run.id}", json_response["url"]
    assert_equal [ "", payload["run_id"] ], [ run.external_tenant, run.external_run_id ],
      "a single-tenant run is identified within the install"

    evaluation = run.evaluation
    assert_equal "orders (eu, support)", evaluation.name, "the report's scope names the evaluation"
    assert_equal "llm", evaluation.judge_kind
    assert_equal "gpt-5-mini", evaluation.judge_model
    assert_equal %w[status_1 refund_1], evaluation.scenarios.ordered.pluck(:key)

    agent = evaluation.agent
    assert agent.observed?, "the reporting application's agent is read-only here"
    assert_equal [ "support-app", "SupportBot", nil, nil ],
      [ agent.service_name, agent.agent_class_name, agent.action_name, agent.user_id ]

    assert_equal [ 4, 3 ], [ run.samples_evaluated, run.samples_passed ]
    assert_equal [ "gpt-5-mini", "openrouter/anthropic/claude-sonnet-5" ], run.models
    failing = run.scenario_results.find_by(model: "anthropic/claude-sonnet-5", status: :failed)
    assert_equal "missing_capability", failing.fault
    assert_equal "Add a refund tool", failing.recommendation
    assert_equal "trace3", failing.replay_metadata["trace_id"], "the result keeps the trace it links to"
  end

  test "stores a run the engine can rebuild into the same report" do
    payload = envelope
    publish(payload)

    rebuilt = ActionAgent::EvaluationRun.find(json_response["id"]).to_report.to_h
    published = payload["report"]
    assert_equal published["models"].keys, rebuilt["models"].keys, "each model keeps the label it was published under"
    assert_equal published["results"].map { |result| result.values_at("scenario_key", "label", "status", "answer") }.sort,
      rebuilt["results"].map { |result| result.values_at("scenario_key", "label", "status", "answer") }.sort
    assert_equal published["judge"], rebuilt["judge"]
    assert_equal published["recommendations"].map { |entry| entry["fault"] }, rebuilt["recommendations"].map { |entry| entry["fault"] }
    assert_equal published.dig("metadata", "scope"), rebuilt.dig("metadata", "scope")
  end

  test "shows the stored report on the dashboard's Evaluations page" do
    publish(envelope)
    evaluation_id = json_response["evaluation_id"]

    get "/activeagents/api/evaluations"

    assert_response :success
    listed = JSON.parse(response.body)["evaluations"].find { |evaluation| evaluation["id"] == evaluation_id }
    assert listed, "the imported evaluation is listed"
    assert listed["scenario_suite"]
    assert_equal "complete", listed.dig("latest_run", "status")
  end

  test "returns the stored run for an identical retry" do
    payload = envelope
    publish(payload)
    first_id = json_response["id"]

    assert_no_difference -> { ActionAgent::EvaluationRun.count } do
      publish(payload)
    end
    assert_response :ok
    assert_equal [ first_id, true ], json_response.values_at("id", "duplicate")
  end

  test "refuses different content under a stored run_id" do
    publish(envelope(run_id: "run-fixed"))
    publish(envelope(run_id: "run-fixed", answer: "Order 1234 is delayed."))

    assert_response :conflict
  end

  test "adds a later run to the same evaluation and scenarios" do
    publish(envelope)
    evaluation_id = json_response["evaluation_id"]
    publish(envelope)

    assert_response :created
    assert_equal evaluation_id, json_response["evaluation_id"]
    evaluation = ActionAgent::Evaluation.find(evaluation_id)
    assert_equal 2, evaluation.evaluation_runs.count
    assert_equal 2, evaluation.scenarios.count
    assert_equal 1, ActionAgent::Agent.count
  end

  test "refuses to add runs to an evaluation no report created, as a report to correct" do
    publish(envelope)
    ActionAgent::Evaluation.find(json_response["evaluation_id"]).update_columns(config: {})
    publish(envelope)

    assert_response :unprocessable_entity, "409 is kept for a run_id that already holds a different report"
    assert_match "publish under another suite or scope", json_response["error"]
  end

  test "stores text with NUL characters removed" do
    payload = envelope
    payload["report"]["results"].first["answer"] = "Order\u00001234"
    publish(payload)

    assert_response :created
    assert_includes ActionAgent::EvaluationRun.find(json_response["id"]).scenario_results.pluck(:output), "Order1234"
  end

  test "summarizes the run from the stored results rather than the report's own summary" do
    payload = envelope
    payload["report"]["models"] = payload["report"]["models"].transform_values { |summary| summary.merge("pass_rate" => 100.0) }
    payload["report"]["recommendations"] = [ nil ]
    publish(payload)

    run = ActionAgent::EvaluationRun.find(json_response["id"])
    assert_equal 50.0, run.scores.dig("_models", "openrouter/anthropic/claude-sonnet-5", "pass_rate")
    assert_equal [ "missing_capability" ], run.scores["_recommendations"].map { |entry| entry["fault"] }
  end

  test "a delivery that loses the race to an identical one returns the stored run" do
    payload = envelope
    publish(payload)
    stored_id = json_response["id"]

    # The first lookup misses, as it would while the other delivery had not
    # yet committed; the insert then collides on the unique index.
    lookups = 0
    find_by = ActionAgent::EvaluationRun.method(:find_by)
    racing = ->(*args, **kwargs) { (lookups += 1) == 1 ? nil : find_by.call(*args, **kwargs) }
    run, duplicate = ActionAgent::EvaluationRun.stub(:find_by, racing) do
      ActionAgent::EvaluationReportImport.call(payload: payload)
    end

    assert_equal [ stored_id, true ], [ run.id, duplicate ]
    assert_equal 1, ActionAgent::EvaluationRun.where(external_run_id: payload["run_id"]).count
  end

  # --- invalid reports ---------------------------------------------------------

  def assert_rejected(payload, message = nil)
    publish(payload)

    assert_response :unprocessable_entity
    assert_match message, json_response["error"] if message
    assert_equal 0, ActionAgent::EvaluationRun.count
  end

  test "rejects a report that is not version 1" do
    assert_rejected envelope.merge("version" => 2), "version must be 1"
  end

  test "rejects a result whose label names no reported model" do
    payload = envelope
    payload["report"]["results"].first["label"] = "unknown-model"

    assert_rejected payload, "missing from report.models"
  end

  test "rejects an unknown fault" do
    payload = envelope
    payload["report"]["results"].first["fault"] = "gremlins"

    assert_rejected payload, "unknown fault"
  end

  test "rejects a verdict whose rationale is not text" do
    payload = envelope
    payload["report"]["verdict"] = { "winner" => "gpt-5-mini", "rationale" => { "x" => 1 } }

    assert_rejected payload, "report.verdict.rationale"
  end

  test "rejects a tool call that is not an object with a name" do
    payload = envelope
    payload["report"]["results"].first["tool_calls"] = [ [ 1 ] ]

    assert_rejected payload, "tool_calls"
  end

  test "rejects a diagnosis whose judge is not an object" do
    payload = envelope
    payload["report"]["results"].first["diagnosis"] = { "judge" => "gpt" }

    assert_rejected payload, "result.diagnosis.judge"
  end

  test "rejects a token count its column cannot hold" do
    payload = envelope
    payload["report"]["results"].first["input_tokens"] = 3_000_000_000

    assert_rejected payload, "result.input_tokens"
  end

  test "rejects a scope value that would read as two" do
    payload = envelope
    payload["report"]["metadata"]["scope"] = "eu, support"

    assert_rejected payload, "report.metadata.scope"
  end

  test "rejects a suite and scope that name an evaluation too long to store" do
    payload = envelope.merge("suite" => "s" * 200)
    payload["report"]["metadata"]["environment"] = "e" * 100

    assert_rejected payload, "longer than 255 characters"
  end

  test "rejects two labels for the same provider and model" do
    payload = envelope
    first = payload["report"]["results"].first
    duplicate = first.merge("label" => "gpt-5-mini-again", "metadata" => first["metadata"].merge("result_id" => "result-extra"))
    payload["report"]["models"]["gpt-5-mini-again"] = payload["report"]["models"]["gpt-5-mini"]
    payload["report"]["results"] << duplicate

    assert_rejected payload, "same provider/model"
  end

  test "rejects a body that is not JSON" do
    publish("{not json")

    assert_response :bad_request
    assert_equal "Invalid JSON", json_response["error"]
  end

  test "rejects a report over the size limit" do
    payload = envelope
    payload["report"]["results"].first["answer"] = "x" * (ActionAgent::EvaluationReportImport::MAX_BYTES + 1)
    publish(payload)

    assert_response 413
    assert_equal 0, ActionAgent::EvaluationRun.count
  end

  # --- limits -----------------------------------------------------------------

  test "the host's evaluation_report quota is enforced with 429 and nothing is stored" do
    ActionAgent.quota_checker = ->(_owner, kind) { { message: "Report allowance used up", used: 10 } if kind == :evaluation_report }

    publish(envelope)

    assert_response :too_many_requests
    assert_equal [ "Evaluation report limit reached", "Report allowance used up", 10 ], json_response.values_at("error", "message", "used")
    assert_equal 0, ActionAgent::EvaluationRun.count
  end

  test "a checker that only limits trace ingest does not block reports" do
    ActionAgent.quota_checker = ->(_owner, kind) { "Out of traces" if kind == :trace_ingest }

    publish(envelope)

    assert_response :created
  end

  test "records one evaluation_report use per stored report, and none for a retry" do
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind) { recorded << [ owner, kind ] }
    payload = envelope

    publish(payload)
    publish(payload)

    assert_equal [ [ nil, :evaluation_report ] ], recorded
  end

  test "refuses a report whose agent would exceed the observed-agent cap" do
    now = Time.current
    ActionAgent::Agent.insert_all(Array.new(ActionAgent::AgentRegistrar::MAX_OBSERVED_PER_OWNER) do |index|
      { name: "Observed #{index}", slug: "observed-#{index}", status: ActionAgent::Agent.statuses[:observed],
        provider: "openai", model: "gpt-5-mini", created_at: now, updated_at: now }
    end)

    publish(envelope)

    assert_response :forbidden, "a cap an operator has to lift is not a retryable 429"
    assert_match "Observed agent limit", json_response["error"]
    assert_equal 0, ActionAgent::EvaluationRun.count
  end

  test "rate-limits a key that publishes too often" do
    Rails.cache.stub(:increment, ActionAgent::Api::EvaluationReportsController::RATE_LIMIT + 1) do
      publish(envelope)
    end

    assert_response :too_many_requests
    assert_equal 0, ActionAgent::EvaluationRun.count
  end

  # --- tenancy ----------------------------------------------------------------

  test "keeps each tenant's runs, agents and dashboard apart" do
    use_tenants!
    first = create_tenant("First")
    second = create_tenant("Second")

    publish(envelope(run_id: "run-shared"), token: first.telemetry_api_key)
    assert_response :created
    first_run = ActionAgent::EvaluationRun.find(json_response["id"])
    publish(envelope(run_id: "run-shared"), token: second.telemetry_api_key)
    assert_response :created, "a run_id is unique within a tenant, not across them"
    second_run = ActionAgent::EvaluationRun.find(json_response["id"])

    assert_equal [ first.id.to_s, second.id.to_s ], [ first_run.external_tenant, second_run.external_tenant ]
    assert_equal [ first.id, second.id ], [ first_run.evaluation.agent.account_id, second_run.evaluation.agent.account_id ],
      "with no owner resolver, each tenant owns its report's agent"

    ActionAgent.current_account_resolver = ->(_controller) { first }
    get "/activeagents/api/evaluations"
    assert_equal [ first_run.evaluation_id ], JSON.parse(response.body)["evaluations"].map { |evaluation| evaluation["id"] },
      "a tenant's dashboard shows its own report and not the other's"
  end

  test "places the agent where the host's trace_owner_resolver puts that tenant's agents" do
    use_tenants!
    ActionAgent.user_class = "User"
    ActionAgent.trace_model_class = "ReportTenantTrace"
    seen = []
    ActionAgent.trace_owner_resolver = lambda do |trace|
      seen << [ trace.service_name, trace.agent_class ]
      trace.account&.owner
    end
    user = create_user("Tenant Owner")
    tenant = create_tenant("Owned", owner: user)

    publish(envelope, token: tenant.telemetry_api_key)

    assert_response :created
    agent = ActionAgent::EvaluationRun.find(json_response["id"]).evaluation.agent
    assert_equal [ user.id, tenant.id ], [ agent.user_id, agent.account_id ]
    assert_includes ActionAgent.agents_for(user), agent
    assert_equal [ [ "support-app", "SupportBot" ] ], seen
  end

  test "rate-limits each tenant's key separately" do
    use_tenants!
    tenant = create_tenant("Limited")
    keys = []
    counting = ->(key, *_rest, **_options) { keys << key; 1 }

    Rails.cache.stub(:increment, counting) { publish(envelope, token: tenant.telemetry_api_key) }

    assert_response :created
    assert_equal 1, keys.size
    assert_match(/account:#{tenant.id}\z/, keys.first)
  end

  # --- retries under quota and rate limits -------------------------------------

  test "an identical retry gets its 200 receipt after the quota is used up" do
    stored = 0
    ActionAgent.usage_recorder = ->(_owner, kind) { stored += 1 if kind == :evaluation_report }
    ActionAgent.quota_checker = ->(_owner, kind) { "Report allowance used up" if kind == :evaluation_report && stored >= 1 }
    payload = envelope

    publish(payload)
    assert_response :created
    publish(payload)
    assert_response :ok, "the report that used the last unit is already stored"
    assert json_response["duplicate"]

    publish(envelope)
    assert_response :too_many_requests, "a new report is still refused"
    assert_equal "Report allowance used up", json_response["message"]
  end

  test "an identical retry gets its 200 receipt when the key is over the rate limit" do
    payload = envelope
    publish(payload)
    assert_response :created

    Rails.cache.stub(:increment, ActionAgent::Api::EvaluationReportsController::RATE_LIMIT + 1) do
      publish(payload)
      assert_response :ok

      publish(envelope)
      assert_response :too_many_requests
    end
  end

  test "a run_id is compared exactly, so run_ids that differ only in case are two runs" do
    publish(envelope(run_id: "nightly-a"))
    assert_response :created
    publish(envelope(run_id: "Nightly-A"))

    assert_response :created
    assert_equal "Nightly-A", json_response["run_id"]
  end

  # --- request handling --------------------------------------------------------

  test "Rails never parses the body into params, so only #create reads it, capped" do
    ActionAgent.ingest_api_key = "install-key"
    seen = []
    capture = ->(*args) { seen << args.last[:params] if args.last[:controller] == "ActionAgent::Api::EvaluationReportsController" }
    padded = envelope.merge("padding" => "x" * (ActionAgent::EvaluationReportImport::MAX_BYTES + 1))

    ActiveSupport::Notifications.subscribed(capture, "start_processing.action_controller") do
      publish(padded)
      assert_response :unauthorized
      publish(envelope, token: "install-key")
      assert_response :created
    end

    assert_equal 2, seen.size
    seen.each { |params| assert_empty params.keys & %w[padding report run_id], "the envelope reached params before #create" }
  end

  test "bounds a chunked body with no Content-Length at the size limit" do
    limit = ActionAgent::EvaluationReportImport::MAX_BYTES
    status, bytes_read = post_chunked(envelope.merge("padding" => "x" * (limit * 2)).to_json)
    assert_equal 413, status
    assert_operator bytes_read, :<=, limit + 1, "the body was read past the limit"

    status, = post_chunked(envelope.to_json)
    assert_equal 201, status
  end

  test "refuses a body that is not declared application/json, as a cross-site form or text/plain post would be" do
    publish(envelope, content_type: "text/plain;charset=UTF-8")
    assert_response :unsupported_media_type

    publish(envelope, content_type: "application/x-www-form-urlencoded")
    assert_response :unsupported_media_type
    assert_equal 0, ActionAgent::EvaluationRun.count
  end

  test "answers 501, not 500, on an install with no evaluation tables" do
    ActionAgent::EvaluationRun.stub(:table_exists?, false) { publish(envelope) }

    assert_response :not_implemented
    assert_match "--traces-only", json_response["error"]
  end

  test "answers 501, not 500, on an install missing a column the import writes" do
    columns = ActionAgent::EvaluationRun.column_names - [ "agent_version_id" ]
    ActionAgent::EvaluationRun.stub(:column_names, columns) { publish(envelope) }

    assert_response :not_implemented
    assert_match "agent_version_id", json_response["error"]
    assert_match "action_agent:install --skip", json_response["error"]
  end

  test "answers 503 with Retry-After when the owner's lock cannot be taken" do
    busy = Object.new
    busy.define_singleton_method(:synchronize) { raise ActionAgent::EvaluationReportImport::Busy, "busy" }

    ActionAgent::EvaluationReportImport::OwnerLock.stub(:new, busy) { publish(envelope) }

    assert_response :service_unavailable
    assert_equal "5", response.headers["Retry-After"]
  end

  # --- envelope identities and report content -----------------------------------

  test "refuses a NUL in an envelope identity rather than storing a different run_id" do
    assert_rejected envelope.merge("run_id" => "nightly-7\u0000"), "run_id must be 1-200 characters without control characters"
    assert_rejected envelope.merge("source" => "support-app\u0000"), "source"
    assert_rejected envelope.merge("agent_name" => "Support\tBot"), "agent_name must be 2-100 characters without control characters"
  end

  test "echoes the run_id exactly as sent" do
    publish(envelope(run_id: "nächtlich/7 run"))

    assert_response :created
    assert_equal "nächtlich/7 run", json_response["run_id"]
  end

  test "records a rules-only run as unjudged even when an earlier report of the suite named a judge" do
    publish(envelope)
    payload = { "version" => 1, "run_id" => "run-rules", "source" => "support-app", "agent_name" => "SupportBot", "suite" => "orders",
                "report" => report(run_id: "run-rules", judge_label: nil).to_h }
    publish(payload)

    assert_response :created
    run = ActionAgent::EvaluationRun.find(json_response["id"])
    assert run.scores.key?("_judge_label")
    assert_nil run.judge_label, "the run must not borrow the evaluation's judge"
    assert_nil run.to_report.to_h["judge"]
  end

  test "refuses a result whose fault or recommendation differs from its diagnosis" do
    payload = envelope
    payload["report"]["results"].first["fault"] = "missing_capability"
    assert_rejected payload, "result.fault must equal result.diagnosis.fault"

    payload = envelope
    payload["report"]["results"].last.delete("fault")
    assert_rejected payload, "result.fault must equal result.diagnosis.fault"

    payload = envelope
    payload["report"]["results"].last["recommendation"] = "Something else"
    assert_rejected payload, "result.recommendation must equal result.diagnosis.recommendation"
  end

  test "stores a prompt, error or recommendation cut to what a MySQL TEXT column holds" do
    limit = ActionAgent::EvaluationReportImport::TEXT_BYTES
    payload = envelope
    failing = payload["report"]["results"].last
    failing["prompt"] = "é" * limit
    failing["error"] = "e" * (limit + 10)
    failing["recommendation"] = failing["diagnosis"]["recommendation"] = "r" * (limit + 10)
    publish(payload)

    assert_response :created
    run = ActionAgent::EvaluationRun.find(json_response["id"])
    row = run.scenario_results.find_by(status: :failed)
    assert_equal [ limit, limit ], [ row.error_message.bytesize, row.recommendation.bytesize ]
    prompt = row.scenario.prompt
    assert prompt.valid_encoding?
    assert_operator prompt.bytesize, :<=, limit
    assert_equal "é" * limit, row.evaluated_scenario["prompt"], "the snapshot keeps the whole prompt for the report"
  end

  # --- ownership and caps -------------------------------------------------------

  test "refuses a multi-tenant report whose owner resolver places it nowhere" do
    use_tenants!
    ActionAgent.trace_owner_resolver = ->(_trace) { nil }

    publish(envelope, token: create_tenant("Unplaced").telemetry_api_key)

    assert_response :forbidden
    assert_match "trace_owner_resolver", json_response["error"]
  end

  test "places a report's agent in the account the resolver names, once, under that account's cap" do
    use_tenants!
    ActionAgent.trace_model_class = "ReportTenantTrace"
    parent = create_tenant("Parent")
    child = create_tenant("Child")
    ActionAgent.trace_owner_resolver = ->(trace) { trace.account == child ? parent : trace.account }

    publish(envelope, token: child.telemetry_api_key)
    assert_response :created
    publish(envelope, token: child.telemetry_api_key)
    assert_response :created

    agents = ActionAgent::Agent.observed_agents.where(service_name: "support-app")
    assert_equal [ parent.id ], agents.pluck(:account_id), "one agent, where the child's traced agents are"
    ActionAgent.current_account_resolver = ->(_controller) { parent }
    get "/activeagents/api/evaluations"
    assert_equal 1, JSON.parse(response.body)["evaluations"].size
  end

  test "refuses a report that would take an evaluation past its scenario cap" do
    publish(envelope)
    evaluation = ActionAgent::Evaluation.find(json_response["evaluation_id"])
    now = Time.current
    ActionAgent::EvaluationScenario.insert_all(Array.new(ActionAgent::EvaluationReportImport::MAX_SCENARIOS_PER_EVALUATION - 2) do |index|
      { evaluation_id: evaluation.id, key: "held_#{index}", prompt: "Held #{index}", position: index + 2, enabled: true,
        expectations: {}, created_at: now, updated_at: now }
    end)

    publish(envelope)
    assert_response :created, "reported scenarios the evaluation already holds add nothing"

    payload = envelope
    payload["report"]["results"].first["scenario_key"] = "brand_new"
    publish(payload)
    assert_response :forbidden
    assert_match "Scenario limit reached", json_response["error"]
  end

  test "refuses a report that would give an agent more evaluations than its cap" do
    publish(envelope)
    agent_id = ActionAgent::Evaluation.find(json_response["evaluation_id"]).agent_id
    now = Time.current
    ActionAgent::Evaluation.insert_all(Array.new(ActionAgent::EvaluationReportImport::MAX_EVALUATIONS_PER_AGENT - 1) do |index|
      { agent_id: agent_id, name: "held #{index}", judge_kind: "rules", sample_size: 20, criteria: [], config: {},
        created_at: now, updated_at: now }
    end)

    payload = envelope
    payload["report"]["metadata"]["scope"] = "us"
    publish(payload)

    assert_response :forbidden
    assert_match "Evaluation limit reached", json_response["error"]
  end

  test "counts only trace ingest through the tenant's increment_telemetry_usage!" do
    use_tenants!
    tenant = create_tenant("Counted")
    ReportTestAccount.telemetry_requests = 0

    publish(envelope, token: tenant.telemetry_api_key)
    assert_response :created
    assert_equal 0, ReportTestAccount.telemetry_requests, "a report post is metered through usage_recorder instead"

    ActionAgent::ProcessTelemetryTracesJob.stub(:perform_later, nil) do
      post "/activeagents/api/traces", params: { traces: [ { trace_id: "t1" } ] }, as: :json,
        headers: { "Authorization" => "Bearer #{tenant.telemetry_api_key}" }
    end
    assert_response :accepted
    assert_equal 1, ReportTestAccount.telemetry_requests
  end

  # --- publishing ----------------------------------------------------------------

  test "ActiveAgent::Evals::Publisher delivers a report the collector stores, and a retry is idempotent" do
    ActionAgent.ingest_api_key = "install-key"
    endpoint = "http://localhost#{ENDPOINT}"
    # WebMock hands the app a plain Hash as rack.session, which Rails' session
    # middleware cannot load; without it the request builds its own.
    app = ->(env) { Rails.application.call(env.except("rack.session", "rack.session.options")) }
    stub_request(:post, endpoint).to_rack(app)
    publisher = Evals::Publisher.new(endpoint: endpoint, api_key: "install-key")
    published = report(run_id: "run-published")

    receipt = publisher.call(report: published, run_id: "run-published", source: "support-app", agent_name: "SupportBot", suite: "orders")
    retried = publisher.call(report: JSON.parse(published.to_json), run_id: "run-published", source: "support-app",
      agent_name: "SupportBot", suite: "orders")

    assert_equal [ "run-published", "complete", false ], receipt.values_at("run_id", "status", "duplicate")
    assert_equal [ receipt["id"], true ], retried.values_at("id", "duplicate"),
      "the saved report's JSON, re-delivered, resolves to the stored run"
    run = ActionAgent::EvaluationRun.find(receipt["id"])
    assert_equal published.to_h["models"].keys, run.to_report.to_h["models"].keys
  end
end

# The advisory lock EvaluationReportImport holds per owner, as SQL issued to
# each adapter. The dummy app runs on SQLite, so the PostgreSQL and MySQL
# statements are checked against a recording connection.
class EvaluationReportOwnerLockTest < ActiveSupport::TestCase
  OwnerLock = ActionAgent::EvaluationReportImport::OwnerLock

  class RecordingConnection
    attr_reader :statements

    def initialize(adapter_name, lock_result: 1)
      @adapter_name = adapter_name
      @lock_result = lock_result
      @statements = []
    end

    attr_reader :adapter_name

    def execute(sql) = @statements << sql

    def select_value(sql)
      @statements << sql
      sql.include?("GET_LOCK") ? @lock_result : 1
    end

    def quote(value) = "'#{value}'"

    def transaction(**) = yield
  end

  test "PostgreSQL takes a transaction-scoped lock in the two-integer keyspace" do
    connection = RecordingConnection.new("PostgreSQL")
    ran = false

    OwnerLock.new(connection, "evaluation_report:install").synchronize { ran = true }

    assert ran
    assert_match(/\ASELECT pg_advisory_xact_lock\(-?\d+, -?\d+\)\z/, connection.statements.sole)
  end

  test "MySQL releases its named lock after the block, even when the block raises" do
    connection = RecordingConnection.new("Mysql2")

    assert_raises(RuntimeError) { OwnerLock.new(connection, "evaluation_report:install").synchronize { raise "import failed" } }

    assert_match(/\ASELECT GET_LOCK\('action_agent:\h{40}', 30\)\z/, connection.statements.first)
    assert_match(/\ASELECT RELEASE_LOCK\('action_agent:\h{40}'\)\z/, connection.statements.last)
  end

  test "MySQL raises Busy without running the block when the lock times out" do
    connection = RecordingConnection.new("Trilogy", lock_result: 0)
    ran = false

    assert_raises(ActionAgent::EvaluationReportImport::Busy) do
      OwnerLock.new(connection, "evaluation_report:install").synchronize { ran = true }
    end
    assert_not ran
    assert_equal 1, connection.statements.size, "a lock never taken is never released"
  end

  test "SQLite, which runs one write transaction at a time, takes no lock" do
    connection = RecordingConnection.new("SQLite")

    assert_equal :ran, OwnerLock.new(connection, "evaluation_report:install").synchronize { :ran }
    assert_empty connection.statements
  end
end
