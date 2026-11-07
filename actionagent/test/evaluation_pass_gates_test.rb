# frozen_string_literal: true

require "test_helper"

# A run's per-group pass gates (ActiveAgent::Evals::Report#gates): the bars
# a dashboard run of a catalog set is held to, recorded as it starts, and
# the bars a published report arrived with, kept on the run so the rebuilt
# report, the run's JSON and the export gate the stored results the same way.
class EvaluationPassGatesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  CRITERIA = [ { "key" => "response_present", "type" => "response_present" } ].freeze

  def setup
    ActionAgent::ScenarioCatalog.destroy_all
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(name: "Checkout Agent", provider: "mock", model: "mock-model", instructions: "Answer with the data.")
    @fan_out = ActionAgent.scenario_evaluation_fan_out
  end

  def teardown
    ActionAgent.scenario_evaluation_fan_out = @fan_out
  end

  # A product whose bar is 60% over a set that must pass every answer:
  # two of its three scenarios pass under the mock provider and the third,
  # expecting a tool the mock never calls, fails.
  def document(product_pass: { "min_pass_rate" => 0.6 }, set_pass: { "min_pass_rate" => 1.0 }, criteria: CRITERIA)
    {
      "catalog" => "order_suite",
      "products" => [ {
        "key" => "checkout", "pass" => product_pass,
        "sets" => [ {
          "key" => "critical", "criteria" => criteria, "pass" => set_pass,
          "scenarios" => [
            { "key" => "charge_once", "prompt" => "Check the duplicate charge." },
            { "key" => "refund_once", "prompt" => "Check the refund." },
            { "key" => "lookup", "prompt" => "Find the order.", "expect" => { "tools" => [ "find_order" ] } }
          ]
        }.compact ]
      }.compact ]
    }
  end

  def import(input = document)
    ActionAgent::ScenarioCatalogImport.new(owner: nil, document: input.to_yaml).call
  end

  def materialized(input = document)
    import(input).sets.sole.materialize!(agent: @agent)
  end

  # An evaluation of one passing scenario, built the way the dashboard
  # builds one by hand.
  def evaluation(name:, **attributes)
    built = @agent.evaluations.new(name: name, judge_kind: "rules", criteria: CRITERIA, **attributes)
    built.scenarios.build(key: "one", prompt: "Hello")
    built.save!
    built
  end

  def critical_gate(run)
    run.gates.find { |gate| gate["group"] == "critical" }
  end

  def all_gate(run)
    run.gates.find { |gate| gate["group"].nil? }
  end

  test "a dashboard run of a catalog set is gated by the set's bars even when its pass rate clears the product's" do
    run = materialized.run!

    assert_equal "complete", run.status, "a missed gate is a verdict, not a failed run"
    assert_equal [ 3, 2 ], [ run.samples_evaluated, run.samples_passed ]
    assert_equal({ "threshold" => 0.7, "min_pass_rate" => 0.6, "groups" => { "critical" => { "min_pass_rate" => 1.0 } } },
      run.scores["_pass_thresholds"])
    assert_equal({ "passed" => 2, "total" => 3, "min_pass_rate" => 1.0, "gated" => true, "met" => false },
      critical_gate(run).slice("passed", "total", "min_pass_rate", "gated", "met"))
    assert_equal({ "min_pass_rate" => 0.6, "met" => true }, all_gate(run).slice("min_pass_rate", "met"))
    assert_equal false, run.gates_met

    report = run.to_report
    assert_not report.passed?
    assert_equal run.gates, report.to_h["gates"]
    assert_equal run.scores["_pass_thresholds"], report.to_h["pass_thresholds"]
  end

  test "an ungated set is reported, not gated" do
    run = materialized(document(set_pass: { "gated" => false })).run!

    assert_equal({ "gated" => false, "met" => true }, critical_gate(run).slice("gated", "met"))
    assert_nil all_gate(run), "no gated result reaches the whole-run gate"
    assert_equal true, run.gates_met
  end

  # An answer present but far short of LONG scores a little over 0.5:
  # below the dashboard's 0.7, above a catalog threshold of 0.4.
  LONG = [ *CRITERIA, { "key" => "long", "type" => "min_length", "config" => { "chars" => 100_000 } } ].freeze

  test "a catalog's threshold scores the run's answers" do
    lenient = materialized(document(product_pass: { "threshold" => 0.4 }, set_pass: nil, criteria: LONG)).run!

    assert_equal 0.4, lenient.scores.dig("_pass_thresholds", "threshold")
    assert_equal 2, lenient.samples_passed
    assert_equal 0, materialized(document(product_pass: nil, set_pass: nil, criteria: LONG)).run!.samples_passed
  end

  test "a fanned-out run scores its answers at the catalog's threshold" do
    ActionAgent.scenario_evaluation_fan_out = true
    run = materialized(document(product_pass: { "threshold" => 0.4 }, set_pass: nil, criteria: LONG)).run_later!
    loop do
      break if enqueued_jobs.empty?

      perform_enqueued_jobs
    end

    assert_equal [ "complete", 2 ], [ run.reload.status, run.samples_passed ]
  end

  test "a finished run keeps the bars it ran with when the catalog changes" do
    run = materialized.run!
    before = run.gates

    import(document(set_pass: { "min_pass_rate" => 0.5 }))
    run.reload

    assert_equal before, run.gates
    assert_equal before, run.to_report.to_h["gates"]
    assert_equal false, run.gates_met
    assert_equal true, materialized(document(set_pass: { "min_pass_rate" => 0.5 })).run!.gates_met, "a new run takes the new bar"
  end

  test "a fanned-out run gates its results with the bars it recorded as it started" do
    ActionAgent.scenario_evaluation_fan_out = true
    evaluation = materialized
    run = evaluation.run_later!
    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)
    import(document(set_pass: { "min_pass_rate" => 0.5 }))
    loop do
      break if enqueued_jobs.empty?

      perform_enqueued_jobs
    end
    run.reload

    assert_equal "complete", run.status
    assert_equal 1.0, critical_gate(run)["min_pass_rate"], "the bar recorded at the start, not the one imported mid-run"
    assert_equal false, run.gates_met
    assert_equal run.gates, run.to_report.to_h["gates"]
  end

  test "a host adapter's run is gated by the set's bars when its report carries none" do
    previous = ActionAgent.scenario_evaluation_adapter_resolver
    ActionAgent.scenario_evaluation_adapter_resolver = lambda do |_evaluation|
      lambda do |scenarios:, models:, on_result:, **|
        ActiveAgent::Evals::Runner.new(
          scenarios: scenarios, models: models, criteria: CRITERIA, on_result: on_result,
          replay: ->(scenario, _spec) { ActiveAgent::Evals::Replay.new(answer: scenario.key == "lookup" ? "" : "The host answered.") }
        ).call
      end
    end

    run = materialized.run!

    assert_equal "complete", run.status
    assert_equal({ "passed" => 2, "total" => 3, "met" => false }, critical_gate(run).slice("passed", "total", "met"))
    assert_equal false, run.gates_met
  ensure
    ActionAgent.scenario_evaluation_adapter_resolver = previous
  end

  test "a run without bars records none and reports as before" do
    plain = materialized(document(product_pass: nil, set_pass: nil)).run!
    adhoc = evaluation(name: "Ad hoc").run!

    [ plain, adhoc ].each do |run|
      assert_equal "complete", run.status
      assert_not run.scores.key?("_pass_thresholds")
      assert_nil run.gates
      assert_nil run.gates_met
      assert_not run.to_report.to_h.key?("gates")
    end
  end

  test "an evaluation pointing at another owner's set is not gated by it" do
    previous = ActionAgent.user_class
    ActionAgent.user_class = "User"
    stranger = User.create!(name: "Stranger", email: "stranger-#{SecureRandom.hex(4)}@example.com", age: 30)
    owner = User.create!(name: "Owner", email: "owner-#{SecureRandom.hex(4)}@example.com", age: 30)
    theirs = ActionAgent::ScenarioCatalogImport.new(owner: stranger, document: document.to_yaml).call.sets.sole
    @agent.update!(user_id: owner.id)
    run = evaluation(name: "Borrowed", config: { "catalog" => theirs.catalog_reference }).run!

    assert_equal "complete", run.status
    assert_nil run.gates
  ensure
    ActionAgent.user_class = previous
  end

  test "a reference whose keys no longer match the set is not gated by it" do
    evaluation = materialized
    evaluation.update!(config: evaluation.config.merge("catalog" => evaluation.config["catalog"].merge("set_key" => "renamed")))

    assert_nil evaluation.run!.gates
  end

  test "a recorded bar that is not one reads as none" do
    run = materialized.run!
    [ "0.8", [], { "groups" => [] }, { "min_pass_rate" => 2 }, { "groups" => { "critical" => { "gated" => "no" } } } ].each do |stored|
      run.update_column(:scores, run.scores.merge("_pass_thresholds" => stored))
      run.reload

      assert_nil run.pass_thresholds, stored.inspect
      assert_not run.to_report.to_h.key?("pass_thresholds"), stored.inspect
    end
  end

  test "the run's JSON carries the gates and whether every one was met" do
    run = materialized.run!
    summary = ActionAgent::EvaluationSerializer.run_summary(run)

    assert_equal run.gates, summary[:gates]
    assert_equal false, summary[:gates_met]
    plain = ActionAgent::EvaluationSerializer.run_summary(materialized(document(product_pass: nil, set_pass: nil)).run!)
    assert_equal [ nil, nil ], plain.values_at(:gates, :gates_met)
    run.update_column(:scores, run.scores.merge("_gates" => []))
    assert_equal false, run.reload.gates_met, "a run that reached no gate has not passed, as Report#passed? says"
  end
end

# The bars a published report carries (Report#to_h["pass_thresholds"]), as
# the collector at <mount>/api/evaluation_reports stores them.
class EvaluationPassGatesImportTest < ActionDispatch::IntegrationTest
  Evals = ActiveAgent::Evals
  ENDPOINT = "/activeagents/api/evaluation_reports"

  def setup
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
  end

  # Ten answers, nine passing: the critical group passes one of its two
  # against a bar of 100%, so the run's pass rate is 90% and it fails.
  def report(pass_thresholds: default_thresholds)
    spec = Evals::ModelSpec.new(label: "gpt-5-mini", provider: "openai", model: "gpt-5-mini")
    results = (1..10).map do |index|
      group = index <= 2 ? "critical" : (index <= 4 ? "informational" : "orders")
      failing = index == 2
      Evals::Result.new(
        scenario: Evals::Scenario.from_hash({ "key" => "case_#{index}", "group" => group, "prompt" => "Case #{index}?" }),
        spec: spec,
        replay: Evals::Replay.new(answer: failing ? "" : "Answer #{index}.", tool_calls: [], duration_ms: 100, input_tokens: 10, output_tokens: 5),
        scores: { "response_present" => failing ? 0.0 : 1.0 }, score: failing ? 0.0 : 1.0, status: failing ? "failed" : "passed"
      )
    end
    Evals::Report.new(results: results, models: [ spec ], pass_thresholds: pass_thresholds)
  end

  def default_thresholds
    Evals::PassThresholds.new(suite: { "min_pass_rate" => 0.8 },
      groups: { "critical" => { "min_pass_rate" => 1.0 }, "informational" => { "gated" => false } })
  end

  def envelope(published = report, run_id: "run-#{SecureRandom.hex(4)}")
    { "version" => 1, "run_id" => run_id, "source" => "ci", "agent_name" => "OrderBot", "suite" => "orders",
      "report" => JSON.parse(published.to_json) }
  end

  def publish(payload)
    post ENDPOINT, params: payload.to_json, headers: { "Content-Type" => "application/json" }
  end

  def stored_run
    ActionAgent::EvaluationRun.sole
  end

  test "a published report's gates come back from the stored run and its export" do
    published = report
    payload = envelope(published)
    publish(payload)
    assert_response :created
    run = stored_run

    assert_equal [ 10, 9 ], [ run.samples_evaluated, run.samples_passed ]
    assert_equal published.to_h["pass_thresholds"], run.scores["_pass_thresholds"]
    assert_equal published.to_h["gates"], run.gates
    assert_equal false, run.gates_met
    assert_equal published.to_h["gates"], run.to_report.to_h["gates"]
    exported = ActionAgent::EvaluationReportExport.new(run).envelope["report"]
    assert_equal published.to_h["pass_thresholds"], exported["pass_thresholds"]
    assert_equal published.to_h["gates"], exported["gates"]

    publish(payload)
    assert_response :success
    assert_equal 1, ActionAgent::EvaluationRun.count, "an identical retry stores nothing new"
    assert_equal published.to_h["gates"], stored_run.gates
  end

  test "the gates are worked out from the results, not taken from the report" do
    payload = envelope
    payload["report"]["gates"].each { |gate| gate["met"] = true }
    publish(payload)
    assert_response :created

    assert_equal false, stored_run.gates_met
  end

  test "a report without bars is stored as before" do
    publish(envelope(report(pass_thresholds: nil)))
    assert_response :created

    assert_not stored_run.scores.key?("_pass_thresholds")
    assert_nil stored_run.gates
    assert_nil stored_run.gates_met
  end

  test "bars the framework would refuse are refused with the reason" do
    {
      "a list" => [ [], "report.pass_thresholds must be an object" ],
      "an unknown key" => [ { "min_pass_rate" => 0.8, "strict" => true }, "unknown keys strict" ],
      "a bar above 1" => [ { "min_pass_rate" => 2 }, "report.pass_thresholds:" ],
      "groups as a list" => [ { "groups" => [] }, "report.pass_thresholds.groups must be an object" ],
      "a gated flag that is not true or false" => [ { "groups" => { "critical" => { "gated" => "no" } } }, "must be true or false" ],
      "a group key the suite cannot have" => [ { "groups" => { "critical" => { "threshold" => 0.5 } } }, "unknown key \"threshold\"" ]
    }.each do |label, (bars, message)|
      payload = envelope
      payload["report"]["pass_thresholds"] = bars
      publish(payload)

      assert_response :unprocessable_entity, label
      assert_includes JSON.parse(response.body)["error"], message, label
      assert_equal 0, ActionAgent::EvaluationRun.count, label
    end
  end

  test "too many groups are refused" do
    payload = envelope
    groups = (0..ActionAgent::EvaluationReportImport::MAX_PASS_GROUPS).to_h { |index| [ "g#{index}", { "gated" => false } ] }
    payload["report"]["pass_thresholds"]["groups"] = groups
    publish(payload)

    assert_response :unprocessable_entity
    assert_includes response.body, "at most #{ActionAgent::EvaluationReportImport::MAX_PASS_GROUPS} groups"
  end
end
