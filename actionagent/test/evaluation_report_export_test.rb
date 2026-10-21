# frozen_string_literal: true

require "test_helper"
require "rake"

# A tenant for the multi-tenant cases, as EvaluationReportsApiTest keeps one.
class ExportTestAccount < ActiveRecord::Base
  def self.ensure_table!
    return if connection.table_exists?(:export_test_accounts)

    connection.create_table :export_test_accounts do |t|
      t.string :name
      t.string :telemetry_api_key
    end
  end
end
ExportTestAccount.ensure_table!

# Exporting a stored evaluation run: the version-1 envelope the collector at
# <mount>/api/evaluation_reports takes, from the API-key route and the
# dashboard's run report, the HTML and Markdown downloads, and the rake tasks.
class EvaluationReportExportTest < ActionDispatch::IntegrationTest
  Evals = ActiveAgent::Evals
  COLLECTOR = "/activeagents/api/evaluation_reports"

  def setup
    ActionAgent::Agent.delete_all
  end

  def teardown
    ActionAgent.ingest_api_key = nil
    ActionAgent.multi_tenant = false
    ActionAgent.account_class = nil
  end

  # --- builders ----------------------------------------------------------------

  def envelope(run_id: "run-#{SecureRandom.hex(4)}")
    specs = [
      Evals::ModelSpec.new(label: "gpt-5-mini", provider: "openai", model: "gpt-5-mini"),
      Evals::ModelSpec.new(label: "sonnet", provider: "anthropic", model: "claude-sonnet-5")
    ]
    scenarios = [
      Evals::Scenario.from_hash({ "key" => "status_1", "group" => "status", "prompt" => "Where is order 1234?" }),
      Evals::Scenario.from_hash({ "key" => "refund_1", "group" => "refunds", "prompt" => "Refund order 1234 | today?" })
    ]
    results = scenarios.product(specs).map do |scenario, spec|
      failing = scenario.key == "refund_1" && spec.label == "sonnet"
      Evals::Result.new(
        scenario: scenario, spec: spec,
        replay: Evals::Replay.new(answer: failing ? "I can't do refunds." : "Order 1234 shipped.", tool_calls: [ { "name" => "lookup_order" } ],
                                  duration_ms: 900, input_tokens: 100, output_tokens: 20, cost: 0.0004),
        scores: { "response_present" => 1.0 }, score: failing ? 0.2 : 1.0, status: failing ? "failed" : "passed",
        diagnosis: failing ? { "fault" => "missing_capability", "summary" => "Declined", "recommendation" => "Add a refund tool" } : nil
      )
    end
    report = Evals::Report.new(results: results, models: specs, judge_label: "gpt-5-mini",
                               metadata: { "run_id" => run_id, "scope" => "eu" })
    Evals::Publisher.envelope(report: report, run_id: run_id, source: "support-app", agent_name: "SupportBot", suite: "orders")
  end

  def publish(payload, token: nil)
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{token}" if token
    post COLLECTOR, params: payload.to_json, headers: headers
  end

  def export(run_id, token: nil, format: nil, download: nil)
    headers = token ? { "Authorization" => "Bearer #{token}" } : {}
    params = { format: format, download: download }.compact
    get "#{COLLECTOR}/#{ERB::Util.url_encode(run_id)}", params: params, headers: headers
  end

  def json_response
    JSON.parse(response.body)
  end

  # A scenario suite the dashboard ran itself: two scenarios under one model.
  def dashboard_run(status: :complete, name: "Orders (eu)")
    agent = ActionAgent::Agent.create!(name: "Assistant", provider: "mock", model: "mock-model", instructions: "Answer from data.")
    evaluation = agent.evaluations.new(name: name, judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "status_1", prompt: "Where is order 1234?", group: "status", position: 0, expectations: { "tools" => [ "lookup_order" ] })
    evaluation.scenarios.build(key: "refund_1", prompt: "Refund it", group: "refunds", position: 1)
    evaluation.save!
    run = evaluation.evaluation_runs.create!(
      status: status, completed_at: Time.current, scores: {},
      selection: { "models" => [ { "label" => "mock-model", "provider" => "mock", "model" => "mock-model" } ] }
    )
    evaluation.scenarios.ordered.each do |scenario|
      passed = scenario.key == "status_1"
      run.scenario_results.create!(
        scenario: scenario, provider: "mock", model: "mock-model", status: passed ? "passed" : "failed", score: passed ? 1.0 : 0.3,
        scores: { "response_present" => 1.0 }, output: passed ? "Shipped." : "No refunds.", tool_calls: [ { "name" => "lookup_order" } ],
        duration_ms: 500, input_tokens: 10, output_tokens: 5, cost: 0.001,
        fault: passed ? nil : "missing_capability", recommendation: passed ? nil : "Add a refund tool",
        diagnosis: passed ? {} : { "fault" => "missing_capability", "summary" => "Declined", "recommendation" => "Add a refund tool",
                                    "judge" => { "suggested_tool" => { "name" => "refund_order" } } }
      )
    end
    run
  end

  # --- the API-key export ------------------------------------------------------

  test "an imported run exports as the envelope it was published in, and posting the export back is an identical retry" do
    payload = envelope
    publish(payload)
    assert_response :created
    stored = json_response

    export(payload["run_id"])

    assert_response :success
    assert_equal "application/json", response.media_type
    exported = json_response
    assert_equal payload.slice("version", "run_id", "source", "agent_name", "suite"), exported.slice("version", "run_id", "source", "agent_name", "suite")
    assert_equal %w[run_id source agent_name suite version report], exported.keys, "the shape Publisher.envelope builds"
    assert_equal payload.dig("report", "results").size, exported.dig("report", "results").size
    assert_equal "eu", exported.dig("report", "metadata", "scope"), "the scope that names the evaluation goes with it"
    assert_not exported.dig("report", "metadata").key?("run"), "the database id stays behind"

    assert_no_difference -> { ActionAgent::EvaluationRun.count } do
      publish(exported)
    end
    assert_response :ok
    assert_equal [ stored["id"], payload["run_id"], true ], json_response.values_at("id", "run_id", "duplicate")

    publish(payload)
    assert_response :ok, "the original report is still an identical retry"

    publish(exported.deep_merge("report" => { "results" => [ exported.dig("report", "results", 0).merge("answer" => "Changed") ] + exported.dig("report", "results").drop(1) }))
    assert_response :conflict, "different content under the run_id is still refused"
  end

  test "the export of a run stores on another install and reads back the same there" do
    payload = envelope
    publish(payload)
    export(payload["run_id"])
    exported = json_response

    # Another install: nothing of the first one left.
    ActionAgent::Agent.destroy_all
    assert_equal 0, ActionAgent::EvaluationRun.count

    publish(exported)
    assert_response :created
    run = ActionAgent::EvaluationRun.find(json_response["id"])
    assert_equal "orders (eu)", run.evaluation.name
    assert_equal 4, run.scenario_results.count

    export(payload["run_id"])
    assert_equal exported, json_response, "an exported run exports unchanged"
  end

  test "a dashboard run exports under a stable run_id that posting back recognizes" do
    run = dashboard_run
    run_id = "dashboard-run-#{run.id}-#{run.created_at.utc.strftime('%Y%m%d%H%M%S')}"
    assert_equal run_id, ActionAgent::EvaluationReportExport.run_id_for(run)

    export(run_id)

    assert_response :success
    exported = json_response
    assert_equal [ run_id, "dummy", "Assistant", "Orders (eu)", 1 ], exported.values_at("run_id", "source", "agent_name", "suite", "version")
    assert_equal %w[status_1 refund_1], exported.dig("report", "results").map { |result| result["scenario_key"] }

    assert_no_difference -> { ActionAgent::EvaluationRun.count } do
      publish(exported)
    end
    assert_response :ok
    assert_equal [ run.id, run_id, true ], json_response.values_at("id", "run_id", "duplicate")

    changed = exported.merge("report" => exported["report"].merge("results" => exported.dig("report", "results").map { |result| result.merge("answer" => "Other") }))
    publish(changed)
    assert_response :conflict

    export("dashboard-run-#{run.id}-20000101000000")
    assert_response :not_found, "the id alone does not name the run"
  end

  test "a run_id with dots resolves without a format" do
    payload = envelope(run_id: "ci.2026.10.21")
    publish(payload)

    export("ci.2026.10.21")

    assert_response :success
    assert_equal "ci.2026.10.21", json_response["run_id"]
  end

  test "an unknown run_id and an incomplete run are refused" do
    export("nope")
    assert_response :not_found

    run = dashboard_run(status: :running)
    export(ActionAgent::EvaluationReportExport.run_id_for(run))
    assert_response :unprocessable_entity
    assert_equal "Only a complete run can be exported", json_response["error"]
  end

  test "format=md returns the report as Markdown" do
    payload = envelope
    publish(payload)

    export(payload["run_id"], format: "md")

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_includes response.body, "<details>\n<summary><code>status_1</code>"
    assert_includes response.body, "## What to fix"
  end

  test "format=html returns the run report page with fix actions linking into the dashboard" do
    run = dashboard_run
    run_id = ActionAgent::EvaluationReportExport.run_id_for(run)

    export(run_id, format: "html")

    assert_response :success
    assert_equal "text/html", response.media_type
    assert_match(/\Ainline; filename="orders-eu-run-1.html"/, response.headers["Content-Disposition"])
    assert_includes response.body, "<!doctype html>"
    assert_includes response.body, %(<html lang="en">), "no theme: the page follows the viewer's preference"
    assert_includes response.body, %(href="/activeagents/tools"), "fix actions link at the dashboard's absolute mount path"
    assert_includes response.body, "Copy as Markdown"
    page = response.body

    get "/activeagents/api/evaluations/#{run.evaluation_id}/runs/#{run.id}/report"
    assert_equal response.body, page, "the same page run_report renders"
  end

  test "download=1 sends any format as an attachment, and an unknown format is refused" do
    run = dashboard_run
    run_id = ActionAgent::EvaluationReportExport.run_id_for(run)

    { nil => [ "application/json", "json" ], "html" => [ "text/html", "html" ], "md" => [ "text/markdown", "md" ] }.each do |format, (type, extension)|
      export(run_id, format: format, download: 1)
      assert_response :success
      assert_equal type, response.media_type
      assert_match(/\Aattachment; filename="orders-eu-run-1.#{extension}"/, response.headers["Content-Disposition"])
    end

    export(run_id, format: "yaml")
    assert_response :unprocessable_entity
    assert_equal "format is one of json, html, md", json_response["error"]
  end

  test "the HTML and Markdown exports authenticate and stay within the tenant" do
    ActionAgent.multi_tenant = true
    ActionAgent.account_class = "ExportTestAccount"
    mine = ExportTestAccount.create!(name: "Mine", telemetry_api_key: "key-mine-html")
    theirs = ExportTestAccount.create!(name: "Theirs", telemetry_api_key: "key-theirs-html")
    payload = envelope
    publish(payload, token: mine.telemetry_api_key)

    %w[html md].each do |format|
      export(payload["run_id"], format: format)
      assert_response :unauthorized

      export(payload["run_id"], format: format, token: "wrong")
      assert_response :unauthorized

      export(payload["run_id"], format: format, token: theirs.telemetry_api_key)
      assert_response :not_found

      export(payload["run_id"], format: format, token: mine.telemetry_api_key)
      assert_response :success
    end
  end

  test "the export authenticates like the collector" do
    payload = envelope
    publish(payload)
    ActionAgent.ingest_api_key = "install-key"

    export(payload["run_id"])
    assert_response :unauthorized

    export(payload["run_id"], token: "install-key")
    assert_response :success
  end

  test "a tenant exports only its own runs" do
    ActionAgent.multi_tenant = true
    ActionAgent.account_class = "ExportTestAccount"
    mine = ExportTestAccount.create!(name: "Mine", telemetry_api_key: "key-mine")
    theirs = ExportTestAccount.create!(name: "Theirs", telemetry_api_key: "key-theirs")
    payload = envelope
    publish(payload, token: mine.telemetry_api_key)
    assert_response :created

    export(payload["run_id"], token: theirs.telemetry_api_key)
    assert_response :not_found

    export(payload["run_id"], token: mine.telemetry_api_key)
    assert_response :success
    exported = json_response

    publish(exported, token: theirs.telemetry_api_key)
    assert_response :created, "another tenant stores the export as its own run"
    export(payload["run_id"], token: theirs.telemetry_api_key)
    assert_response :success

    run = dashboard_run
    run.evaluation.agent.update_columns(account_id: mine.id)
    run_id = ActionAgent::EvaluationReportExport.run_id_for(run)
    export(run_id, token: theirs.telemetry_api_key)
    assert_response :not_found
    export(run_id, token: mine.telemetry_api_key)
    assert_response :success
  end

  # --- the dashboard's run report ----------------------------------------------

  test "the run report serves the envelope as JSON and every format as a download" do
    run = dashboard_run
    base = "/activeagents/api/evaluations/#{run.evaluation_id}/runs/#{run.id}/report"

    get "#{base}.json"
    assert_response :success
    assert_equal ActionAgent::EvaluationReportExport.run_id_for(run), json_response["run_id"]
    assert_nil response.headers["Content-Disposition"]

    get base, params: { format: "json", download: 1 }
    assert_response :success
    assert_equal %(attachment; filename="orders-eu-run-1.json"; filename*=UTF-8''orders-eu-run-1.json), response.headers["Content-Disposition"]

    get base, params: { download: 1 }
    assert_response :success
    assert_equal "text/html", response.media_type
    assert_match(/\Aattachment; filename="orders-eu-run-1.html"/, response.headers["Content-Disposition"])
    assert_includes response.body, "<!doctype html>"

    get "#{base}.md"
    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_includes response.body, "# Evaluation — 2 scenarios × 1 model"
    assert_nil response.headers["Content-Disposition"]

    get "#{base}.md", params: { download: 1 }
    assert_match(/\Aattachment; filename="orders-eu-run-1.md"/, response.headers["Content-Disposition"])
  end

  test "the run report serves each Markdown piece the copy buttons read" do
    run = dashboard_run
    base = "/activeagents/api/evaluations/#{run.evaluation_id}/runs/#{run.id}/report.md"
    report = run.to_report(links: {})

    get base, params: { part: "fix_items" }
    assert_equal report.fix_items_markdown, response.body

    get base, params: { part: "fix_items", model: "mock-model" }
    assert_equal report.fix_items_markdown(model: "mock-model"), response.body

    get base, params: { part: "verdict" }
    assert_equal report.verdict_markdown, response.body

    get base, params: { part: "scenario", scenario: "status_1" }
    assert_equal report.scenario_markdown("status_1"), response.body
    assert_includes response.body, "- Expects tools: `lookup_order`"

    get base, params: { part: "scenario", scenario: "missing" }
    assert_response :not_found

    get base, params: { part: "bogus" }
    assert_response :unprocessable_entity

    get base, params: { part: "fix_items", download: 1 }
    assert_match(/filename="orders-eu-run-1-fix-items.md"/, response.headers["Content-Disposition"])
  end

  test "the run's fix items carry the Markdown their card copies" do
    run = dashboard_run

    get "/activeagents/api/evaluations/#{run.evaluation_id}/runs/#{run.id}"

    item = json_response.dig("run", "fix_items", 0)
    assert_equal run.to_report(links: {}).fix_item_markdown(item.except("markdown")), item["markdown"]
    assert_includes item["markdown"], "missing capability"
  end

  test "a run report outside the signed-in owner's scope is not found" do
    run = dashboard_run
    get "/activeagents/api/evaluations/#{run.evaluation_id + 1000}/runs/#{run.id}/report.json"
    assert_response :not_found
  end

  # --- rake --------------------------------------------------------------------

  test "the rake tasks export a run and import it, an identical retry the second time" do
    run = dashboard_run
    Dir.mktmpdir do |dir|
      file = File.join(dir, "run.json")

      out = with_env("EVALUATION" => run.evaluation_id.to_s, "RUN" => run.id.to_s, "FORMAT" => "json", "FILE" => file) do
        run_task("action_agent:evaluations:export")
      end
      assert_match(/Wrote run dashboard-run-#{run.id}-\d{14} of Orders \(eu\) \(json\)/, out)
      assert_equal ActionAgent::EvaluationReportExport.new(run).envelope, JSON.parse(File.read(file))

      markdown = with_env("RUN" => ActionAgent::EvaluationReportExport.run_id_for(run), "FORMAT" => "md") { run_task("action_agent:evaluations:export") }
      assert_includes markdown, "<details>"

      html = with_env("EVALUATION" => run.evaluation_id.to_s, "RUN" => run.id.to_s, "FORMAT" => "html") { run_task("action_agent:evaluations:export") }
      assert_includes html, "<!doctype html>"

      out = with_env("FILE" => file) { run_task("action_agent:evaluations:import") }
      assert_match(/\AAlready stored \(identical retry\): run dashboard-run-#{run.id}-\d{14} as run ##{run.id} /, out)

      imported = File.join(dir, "imported.json")
      File.write(imported, envelope(run_id: "from-file").to_json)
      out = with_env("FILE" => imported) { run_task("action_agent:evaluations:import") }
      assert_match(/\AStored: run from-file as run #\d+ of evaluation #\d+ \(orders \(eu\)\), complete/, out)
    end
  end

  private

  def with_env(values)
    previous = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  # Invokes +name+ in a fresh Rake application holding the engine's tasks, as
  # `bin/rails <name>` would, and returns what it printed.
  def run_task(name)
    original = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    ActionAgent::Engine.instance.load_tasks
    out, = capture_io { Rake::Task[name].invoke }
    out
  ensure
    Rake.application = original
  end
end
