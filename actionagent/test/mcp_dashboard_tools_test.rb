# frozen_string_literal: true

require "test_helper"

# The dashboard's evaluation and telemetry tools on the MCP facade: a coding
# harness lists and runs an agent's evaluations, reads a run's results and
# fix items, and reads the traces behind them, all under the API key's owner.
class McpDashboardToolsTest < ActionDispatch::IntegrationTest
  RUNTIME_TOKEN = "aa_runtime_dashboard_tools_s3cret"
  DASHBOARD_TOOLS = %w[
    evaluations_list evaluations_get evaluations_create scenarios_merge explorations_submit evaluations_run
    evaluation_runs_get evaluation_runs_compare traces_search traces_get input_requests_list input_requests_answer
  ].freeze

  # A trace model whose tenant is its service name, so a multi-tenant scope
  # can be exercised without an account column on the dummy app's table.
  class TenantTrace < ActionAgent::TelemetryTrace
    def self.for_account(account)
      where(service_name: "tenant-#{account&.id}")
    end
  end

  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::ApiKey.delete_all
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::SandboxSession.delete_all
    @key = ActionAgent::ApiKey.create!(name: "Harness")
    @agent = ActionAgent::Agent.create!(name: "Support", slug: "support", provider: "mock", model: "mock-model",
                                        instructions: "Answer from data.", status: :active)
    @suite = create_suite(@agent)
  end

  def teardown
    ActionAgent.mcp_dashboard_tools = nil
    ActionAgent.execution_enabled = true
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.multi_tenant = false
    ActionAgent.trace_model_class = nil
  end

  def rpc(method, params = {}, key: @key)
    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{key.token}" }
    JSON.parse(response.body)
  end

  def call_tool(name, arguments = {}, key: @key)
    rpc("tools/call", { name: name, arguments: arguments }, key: key)
  end

  def structured(body)
    assert_nil body["error"], body.inspect
    body.dig("result", "structuredContent")
  end

  test "tools/list offers the dashboard tools, and the switch withdraws them" do
    names = rpc("tools/list").dig("result", "tools").map { |tool| tool["name"] }
    assert_empty DASHBOARD_TOOLS - names
    assert_includes names, "run_support"
    assert_match(/evaluations_run/, rpc("initialize").dig("result", "instructions"))

    ActionAgent.mcp_dashboard_tools = false

    names = rpc("tools/list").dig("result", "tools").map { |tool| tool["name"] }
    assert_empty DASHBOARD_TOOLS & names
    assert_includes names, "run_support"
    assert_equal(-32602, call_tool("evaluations_list").dig("error", "code"))
    assert_no_match(/evaluations_run/, rpc("initialize").dig("result", "instructions"))
  end

  test "no dashboard tool name has a prefix a schema tool or an agent tool uses" do
    DASHBOARD_TOOLS.each do |name|
      assert_no_match(/\A(find|count|get|run)_/, name)
    end
  end

  test "evaluations_list lists the key's evaluations with their latest run, filtered by agent" do
    other_agent = ActionAgent::Agent.create!(name: "Billing", slug: "billing", provider: "mock", model: "mock-model")
    create_suite(other_agent)
    run = @suite.evaluation_runs.create!(status: :complete, samples_evaluated: 1, samples_passed: 1, completed_at: Time.current)

    all = structured(call_tool("evaluations_list"))["evaluations"]
    assert_equal 2, all.size

    only = structured(call_tool("evaluations_list", { agent: "support" }))["evaluations"]
    assert_equal [ @suite.id ], only.map { |evaluation| evaluation["id"] }
    assert_equal "support", only.first.dig("agent", "slug")
    assert_equal run.id, only.first.dig("latest_run", "id")
    assert_equal 1, only.first.dig("latest_run", "number")
    assert_equal true, only.first["scenario_suite"]

    body = call_tool("evaluations_list", { agent: "nobody" })
    assert_equal true, body.dig("result", "isError")
  end

  test "evaluations_get returns the evaluation, its scenarios and its recent runs" do
    @suite.evaluation_runs.create!(status: :complete, completed_at: Time.current)

    result = structured(call_tool("evaluations_get", { evaluation_id: @suite.id }))

    assert_equal @suite.id, result.dig("evaluation", "id")
    assert_equal [ "order_lookup" ], result["scenarios"].map { |scenario| scenario["key"] }
    assert_equal 1, result["runs"].size
    assert_equal false, result["scenarios_truncated"]
  end

  test "a missing evaluation id is a JSON-RPC invalid-params error" do
    assert_equal(-32602, call_tool("evaluations_get").dig("error", "code"))
  end

  test "another owner's evaluation reads exactly as a nonexistent one" do
    ActionAgent.user_class = "User"
    me = User.create!(email: "me-#{SecureRandom.hex(3)}@example.com", name: "Me", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    @agent.update_columns(user_id: stranger.id)
    @key.update_columns(user_id: me.id)
    run = @suite.evaluation_runs.create!(status: :complete)
    missing = ActionAgent::Evaluation.maximum(:id).to_i + 100

    assert_empty structured(call_tool("evaluations_list"))["evaluations"]
    %w[evaluations_get evaluations_run evaluation_runs_get evaluation_runs_compare].each do |tool|
      theirs = call_tool(tool, { evaluation_id: @suite.id, run_id: run.id })
      nothing = call_tool(tool, { evaluation_id: missing, run_id: run.id })

      assert_equal true, theirs.dig("result", "isError"), tool
      assert_equal nothing.dig("result", "content", 0, "text").sub(missing.to_s, "ID"),
                   theirs.dig("result", "content", 0, "text").sub(@suite.id.to_s, "ID"), tool
    end
    assert_empty @suite.evaluation_runs.where.not(id: run.id)
  end

  test "evaluations_run queues a scenario suite in the background and returns the pending run" do
    result = nil
    assert_enqueued_jobs 1, only: ActionAgent::EvaluationRunJob do
      result = structured(call_tool("evaluations_run", { evaluation_id: @suite.id, keys: [ "order_lookup" ], models: [ "mock/alpha" ] }))
    end

    assert_equal "pending", result.dig("run", "status")
    assert_equal true, result["background"]
    assert_equal({ "keys" => [ "order_lookup" ], "models" => [ "mock/alpha" ] }, result.dig("run", "selection"))
    assert_equal @suite.evaluation_runs.sole.id, result.dig("run", "id")
  end

  test "a run started over MCP completes in the background and reads back with its results" do
    started = nil
    perform_enqueued_jobs do
      started = structured(call_tool("evaluations_run", { evaluation_id: @suite.id }))
    end

    result = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id, run_id: started.dig("run", "id") }))

    assert_equal "complete", result.dig("run", "status"), result.dig("run", "error_message")
    assert_equal 1, result["results_total"]
    assert_equal "order_lookup", result["results"].first["scenario_key"]
  end

  test "evaluations_run honours the execution switch and the execution quota, as run_<slug> does" do
    ActionAgent.execution_enabled = false
    body = call_tool("evaluations_run", { evaluation_id: @suite.id })
    assert_equal(-32000, body.dig("error", "code"))
    assert_match(/disabled/, body.dig("error", "message"))

    ActionAgent.execution_enabled = true
    ActionAgent.quota_checker = ->(_owner, kind) { { message: "Out of runs" } if kind == :execution }
    body = call_tool("evaluations_run", { evaluation_id: @suite.id })
    assert_equal(-32000, body.dig("error", "code"))
    assert_equal "Out of runs", body.dig("error", "message")

    assert_empty @suite.evaluation_runs
  end

  test "a sampling evaluation is not gated: it scores recorded data" do
    sampling = @agent.evaluations.create!(
      name: "Recorded", judge_kind: "rules", criteria: [ { "key" => "present", "type" => "response_present", "config" => {} } ]
    )
    ActionAgent.execution_enabled = false

    result = structured(call_tool("evaluations_run", { evaluation_id: sampling.id }))

    assert_equal false, result["background"]
    assert_includes %w[complete failed], result.dig("run", "status")
  end

  test "an observed agent's suite is refused as a correctable tool error" do
    @agent.update!(status: :observed)

    body = call_tool("evaluations_run", { evaluation_id: @suite.id })

    assert_equal true, body.dig("result", "isError")
    assert_match(/read-only/, body.dig("result", "content", 0, "text"))
  end

  test "evaluations_run refuses a sandbox exactly as the REST run does, and never echoes its token" do
    unknown = SecureRandom.uuid
    sampling = @agent.evaluations.create!(
      name: "Recorded", judge_kind: "rules", criteria: [ { "key" => "present", "type" => "response_present", "config" => {} } ]
    )
    booting = live_sandbox
    booting.update!(status: :provisioning)

    {
      [ @suite, unknown ] => /No sandbox #{unknown} of yours/,
      [ @suite, booting.session_id ] => /is provisioning/,
      [ sampling, booting.session_id ] => /Only a scenario evaluation runs the agent/,
      [ @suite, 42 ] => /must be a sandbox's session id/
    }.each do |(evaluation, sandbox_id), message|
      body = call_tool("evaluations_run", { evaluation_id: evaluation.id, sandbox_id: sandbox_id })
      assert_equal true, body.dig("result", "isError"), sandbox_id.inspect
      assert_match message, body.dig("result", "content", 0, "text")
    end
    assert_empty @suite.evaluation_runs

    sandbox = live_sandbox
    result = structured(call_tool("evaluations_run", { evaluation_id: @suite.id, sandbox_id: sandbox.session_id }))
    assert_equal sandbox.session_id, result.dig("run", "sandbox", "session_id")
    assert_not_includes response.body, RUNTIME_TOKEN
  end

  test "evaluation_runs_get returns scores, results and fix items, bounded, and masks the owner's credentials" do
    sandbox = live_sandbox
    run = completed_run(output: "Order ABC-123 shipped. debug: #{RUNTIME_TOKEN} #{'x' * 3_000}")

    result = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id }))

    assert_equal run.id, result.dig("run", "id")
    assert_equal "complete", result.dig("run", "status")
    assert result["fix_items"].is_a?(Array)
    assert_operator result["fix_items"].size, :>=, 1
    assert_equal 2, result["results_total"]
    row = result["results"].find { |entry| entry["model"] == "mock/alpha" }
    assert_equal "failed", row["status"]
    assert_equal "order_lookup", row["scenario_key"]
    assert_match(/…\[truncated: \d+ more characters\]\z/, row["output"])
    assert_includes row["output"], ActionAgent::SecretScrubber::MASK
    assert_not_includes response.body, RUNTIME_TOKEN
    assert_not_includes response.body, sandbox.runtime_mcp_token

    failed = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id, run_id: run.id, failed_only: true, limit: 1 }))
    assert_equal 1, failed["results_total"]
    assert_equal 1, failed["results"].size
    assert_equal [ "failed" ], failed["results"].map { |entry| entry["status"] }
    assert_equal 0, failed["results_omitted"]
  end

  test "a remote Ollama host's API key is masked like the other credentials" do
    ActionAgent::ProviderKey.delete_all
    ollama_key = "ollama_bearer_dashboard_tools_s3cret"
    ActionAgent::ProviderKey.create!(provider: "ollama", credential: "http://ollama.internal:11434", api_key: ollama_key)
    completed_run(output: "Order ABC-123 shipped. debug: #{ollama_key}")

    result = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id }))

    assert_includes result["results"].find { |entry| entry["model"] == "mock/alpha" }["output"], ActionAgent::SecretScrubber::MASK
    assert_not_includes response.body, ollama_key
  end

  test "a member's personal provider key is masked like the organization's" do
    ActionAgent::ProviderKey.delete_all
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    ActionAgent.multi_tenant = true
    account = User.create!(email: "acme-#{SecureRandom.hex(3)}@example.com", name: "Acme", age: 30)
    member = User.create!(email: "ada-#{SecureRandom.hex(3)}@example.com", name: "Ada", age: 30)
    @key.update_columns(account_id: account.id)
    @agent.update_columns(user_id: account.id)
    personal = "sk-personal-dashboard-tools-s3cret"
    ActionAgent::ProviderKey.create!(provider: "openai", credential: personal, account_id: account.id, scope_key: "user:#{member.id}")
    completed_run(output: "Order ABC-123 shipped. debug: #{personal}")

    result = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id }))

    assert_includes result["results"].find { |entry| entry["model"] == "mock/alpha" }["output"], ActionAgent::SecretScrubber::MASK
    assert_not_includes response.body, personal
  end

  test "a project's secret is masked with its encodings, like the other credentials" do
    ActionAgent::Project.delete_all
    ActionAgent::ProjectSecret.delete_all
    secret = "sk_test_dashboard tools/project+0123"
    project = ActionAgent::Project.create!(name: "Shop", repository: "acme/shop", install_state: "detected")
    project.assign_secret(name: "STRIPE_SECRET_KEY", value: secret).save!
    completed_run(output: "env: #{secret} #{[ secret ].pack("m0")} #{CGI.escape(secret)}")

    result = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id }))

    assert_includes result["results"].find { |entry| entry["model"] == "mock/alpha" }["output"], ActionAgent::SecretScrubber::MASK
    ActionAgent::SecretScrubber.with_encodings([ secret ]).each do |form|
      assert_not_includes response.body, form
    end
  ensure
    ActionAgent::Project.delete_all
    ActionAgent::ProjectSecret.delete_all
  end

  test "the owner's other dashboard API keys are masked like the other credentials" do
    other_key = ActionAgent::ApiKey.create!(name: "CI")
    completed_run(output: "Order ABC-123 shipped. debug: #{other_key.token}")

    result = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id }))

    assert_includes result["results"].find { |entry| entry["model"] == "mock/alpha" }["output"], ActionAgent::SecretScrubber::MASK
    assert_not_includes response.body, other_key.token
  end

  test "evaluation_runs_get pages results by limit and counts the rest" do
    run = @suite.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    scenario = @suite.scenarios.sole
    25.times { |index| run.scenario_results.create!(scenario: scenario, provider: "mock", model: "mock/m#{index}", status: :passed) }

    all = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id, limit: 500 }))
    page = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id, limit: 10 }))

    assert_equal 25, all["results"].size
    assert_equal [ 10, 25, 15 ], [ page["results"].size, page["results_total"], page["results_omitted"] ]
  end

  test "a result names its trace only when telemetry recorded one" do
    run = completed_run
    recorded, unrecorded = run.scenario_results.order(:model).to_a
    trace = create_trace(agent_class: "SupportAgent")
    recorded.update!(agent_run: ActionAgent::AgentRun.create!(agent: @agent, trace_id: trace.trace_id, input_prompt: "Where?"))
    unrecorded.update!(agent_run: ActionAgent::AgentRun.create!(agent: @agent, input_prompt: "Where?"))

    rows = structured(call_tool("evaluation_runs_get", { evaluation_id: @suite.id }))["results"].index_by { |row| row["id"] }

    assert_equal trace.trace_id, rows[recorded.id]["trace_id"]
    assert_nil rows[unrecorded.id]["trace_id"]
    assert_equal unrecorded.agent_run_id, rows[unrecorded.id]["agent_run_id"]
  end

  test "evaluation_runs_compare reports fixed, regressed and still-failing results" do
    base = completed_run(alpha: :failed, beta: :passed, created_at: 1.hour.ago)
    head = completed_run(alpha: :passed, beta: :failed)

    result = structured(call_tool("evaluation_runs_compare", { evaluation_id: @suite.id }))

    assert_equal base.id, result.dig("base_run", "id")
    assert_equal head.id, result.dig("head_run", "id")
    changes = result["changes"].to_h { |change| [ change["model"], change["change"] ] }
    assert_equal({ "mock/alpha" => "fixed", "mock/beta" => "regressed" }, changes)
    assert_equal({ "fixed" => 1, "regressed" => 1 }, result["counts"])
  end

  test "traces_search filters, bounds and orders newest first, without spans" do
    30.times { |index| create_trace(agent_class: "SupportAgent", timestamp: (index + 1).minutes.ago, input: 10, output: 10) }
    failed = create_trace(agent_class: "SupportAgent", status: "ERROR", error: "Tool lookup_order failed", input: 900, output: 200)
    create_trace(agent_class: "BillingAgent", input: 5, output: 5)

    result = structured(call_tool("traces_search", { agent: "SupportAgent" }))
    assert_equal 20, result["traces"].size
    assert_equal true, result["truncated"]
    assert_equal failed.trace_id, result["traces"].first["trace_id"]
    assert_nil result["traces"].first["spans"]
    timestamps = result["traces"].map { |row| row["timestamp"] }
    assert_equal timestamps.sort.reverse, timestamps

    errors = structured(call_tool("traces_search", { status: "error" }))["traces"]
    assert_equal [ failed.trace_id ], errors.map { |row| row["trace_id"] }

    heavy = structured(call_tool("traces_search", { min_tokens: 1_000 }))["traces"]
    assert_equal [ failed.trace_id ], heavy.map { |row| row["trace_id"] }

    assert_equal 32, structured(call_tool("traces_search", { limit: 5_000 }))["traces"].size
    assert_equal 1, structured(call_tool("traces_search", { limit: 1 }))["traces"].size
  end

  test "traces_search accepts a dashboard agent's slug" do
    trace = create_trace(agent_class: "SomethingElse")
    trace.update_columns(agent_id: @agent.id)
    create_trace(agent_class: "Unrelated")

    rows = structured(call_tool("traces_search", { agent: "support" }))["traces"]

    assert_equal [ trace.trace_id ], rows.map { |row| row["trace_id"] }
  end

  test "traces_get returns spans, tool calls and errors, cutting large values and long span lists" do
    trace = create_trace(agent_class: "SupportAgent", status: "ERROR", error: "boom", spans: 150, big_attribute: "y" * 5_000)

    result = structured(call_tool("traces_get", { trace_id: trace.trace_id.first(8) }))

    assert_equal trace.trace_id, result["trace_id"]
    assert_equal 100, result["spans"].size
    assert_equal 151, result["spans_total"]
    assert_equal 51, result["spans_omitted"]
    assert_equal "lookup_order", result["tool_calls"].first["name"]
    assert_match(/…\[truncated: 4000 more characters\]\z/, result["tool_calls"].first["result"])
    assert_equal "boom", result["error"]
    assert result["failed_spans"].any? { |span| span["message"] == "lookup failed" }

    assert_equal true, call_tool("traces_get", { trace_id: "does-not-exist" }).dig("result", "isError")
    assert_equal(-32602, call_tool("traces_get").dig("error", "code"))
  end

  test "in a multi-tenant install another tenant's trace reads as a nonexistent one" do
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    ActionAgent.multi_tenant = true
    ActionAgent.trace_model_class = "McpDashboardToolsTest::TenantTrace"
    mine = User.create!(email: "mine-#{SecureRandom.hex(3)}@example.com", name: "Mine", age: 30)
    theirs = User.create!(email: "theirs-#{SecureRandom.hex(3)}@example.com", name: "Theirs", age: 30)
    @key.update_columns(account_id: mine.id)
    # Starts with a letter, so the lookup of `other`'s numeric id below cannot
    # match it as a trace id prefix.
    own = create_trace(agent_class: "SupportAgent", service: "tenant-#{mine.id}", trace_id: "e#{SecureRandom.hex(16)[1..]}")
    other = create_trace(agent_class: "SupportAgent", service: "tenant-#{theirs.id}")

    rows = structured(call_tool("traces_search"))["traces"]
    assert_equal [ own.trace_id ], rows.map { |row| row["trace_id"] }

    assert_equal own.trace_id, structured(call_tool("traces_get", { trace_id: own.trace_id }))["trace_id"]
    theirs_body = call_tool("traces_get", { trace_id: other.trace_id })
    nothing_body = call_tool("traces_get", { trace_id: "f" * 32 })
    assert_equal true, theirs_body.dig("result", "isError")
    assert_equal nothing_body.dig("result", "content", 0, "text").sub("f" * 32, "ID"),
                 theirs_body.dig("result", "content", 0, "text").sub(other.trace_id, "ID")
    assert_equal true, call_tool("traces_get", { trace_id: other.id.to_s }).dig("result", "isError")
  end

  test "dashboard reads need no execution switch and spend no execution quota" do
    ActionAgent.execution_enabled = false
    recorded = []
    ActionAgent.usage_recorder = ->(_owner, kind) { recorded << kind }
    create_trace(agent_class: "SupportAgent")

    %w[evaluations_list traces_search].each { |tool| structured(call_tool(tool)) }
    structured(call_tool("evaluations_get", { evaluation_id: @suite.id }))

    assert_empty recorded
  end

  private

  def create_suite(agent)
    evaluation = agent.evaluations.new(name: "#{agent.name} lookups", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "order_lookup", prompt: "Where is order ABC-123?", group: "orders",
                               expectations: { "contains" => [ "shipped" ] })
    evaluation.save!
    evaluation
  end

  # A completed run with one result per model: mock/alpha and mock/beta.
  def completed_run(alpha: :failed, beta: :passed, output: "Order ABC-123 is on its way.", created_at: Time.current)
    run = @suite.evaluation_runs.create!(status: :complete, samples_evaluated: 2, completed_at: created_at, created_at: created_at)
    scenario = @suite.scenarios.sole
    { "mock/alpha" => alpha, "mock/beta" => beta }.each do |model, status|
      failed = status == :failed
      run.scenario_results.create!(
        scenario: scenario, provider: "mock", model: model, status: status, score: failed ? 0.0 : 1.0,
        output: failed ? output : "Order ABC-123 shipped.", fault: failed ? "missing_content" : nil,
        recommendation: failed ? "Say whether the order shipped." : nil,
        diagnosis: failed ? { "fault" => "missing_content", "summary" => "The answer never said shipped.",
                              "recommendation" => "Say whether the order shipped." } : nil,
        tool_calls: [ { "name" => "lookup_order", "arguments" => { "id" => "ABC-123" } } ]
      )
    end
    run
  end

  def create_trace(agent_class:, status: "OK", error: nil, timestamp: Time.current, input: 10, output: 10,
                   spans: 1, big_attribute: nil, service: "support-hub", trace_id: SecureRandom.hex(16))
    rows = [ {
      "span_id" => "root", "parent_span_id" => nil, "name" => "#{agent_class}.answer", "type" => "root",
      "start_time" => timestamp.iso8601(6), "duration_ms" => 120.0, "status" => status,
      "tokens" => { "input" => input, "output" => output }
    } ]
    spans.times do |index|
      rows << {
        "span_id" => "tool#{index}", "parent_span_id" => "root", "name" => "tool.lookup_order", "type" => "tool",
        "start_time" => timestamp.iso8601(6), "duration_ms" => 5.0, "status" => index.zero? && error ? "ERROR" : "OK",
        "attributes" => {
          "tool.name" => "lookup_order", "tool.input.args" => { "id" => "ABC-123" }.to_json,
          "tool.output.result" => big_attribute || "shipped"
        }.merge(index.zero? && error ? { "error.message" => "lookup failed" } : {})
      }
    end

    trace = ActionAgent::TelemetryTrace.create_from_payload({
      "trace_id" => trace_id, "service_name" => service, "environment" => "test",
      "timestamp" => timestamp.iso8601(6), "spans" => rows,
      "resource_attributes" => { "agent.class" => agent_class }
    })
    trace.update_columns(agent_class: agent_class, status: status, error_message: error, timestamp: timestamp,
                         total_input_tokens: input, total_output_tokens: output)
    trace
  end

  def live_sandbox
    sandbox = ActionAgent::SandboxSession.new(
      session_id: SecureRandom.uuid, sandbox_type: "app_runtime", repository: "acme/shop", repository_ref: "experiment"
    )
    sandbox.save!(validate: false)
    sandbox.mark_ready!(cloud_run_url: "http://127.0.0.1:4100", runtime_mcp_url: "http://127.0.0.1:4100/activeagents/mcp",
                        runtime_mcp_token: RUNTIME_TOKEN)
    sandbox
  end
end
