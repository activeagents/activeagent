# frozen_string_literal: true

require "test_helper"

# The scenario-suite half of the evaluations API: creating an evaluation
# from pasted messages, managing its scenarios, running a selection under
# chosen models, and reading a run's per-scenario results.
class ActionAgentScenarioEvaluationsApiTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
  end

  def create_agent
    ActionAgent::Agent.create!(name: "Assistant", provider: "mock", model: "mock-model", instructions: "Answer from data.")
  end

  CATALOG = <<~TEXT
    # Find records
    1. `Which gynecologists in Charlotte have scheduling enabled?` — 314 locally
    2. `Show me all providers with no license on file` | tools: find_records
    # Blame
    3. Who changed the biography for Dr. AbdelRazek?
  TEXT

  test "pasting a list of messages creates a scenario suite and queues its first run" do
    agent = create_agent

    post "/activeagents/api/evaluations", params: {
      evaluation: { agent_id: agent.id, name: "Question catalog", scenarios_text: CATALOG, compare_models: "mock/alpha, mock/beta" }
    }, as: :json

    assert_response :created
    body = JSON.parse(response.body)["evaluation"]
    assert body["scenario_suite"]
    assert_equal 3, body["scenario_count"]
    assert_equal [ "Blame", "Find records" ], body["scenario_groups"]
    assert_equal %w[mock/alpha mock/beta], body["compare_models"]
    assert_equal "pending", body.dig("latest_run", "status")

    evaluation = ActionAgent::Evaluation.find(body["id"])
    assert_equal %w[find_records_1 find_records_2 blame_1], evaluation.scenarios.ordered.map(&:key)
    assert_equal [ "find_records" ], evaluation.scenarios.find_by!(key: "find_records_2").expected_tools
    assert_enqueued_jobs 1, only: ActionAgent::EvaluationRunJob
  end

  test "a suite with no criteria is valid: the scenarios' expectations score it" do
    agent = create_agent

    post "/activeagents/api/evaluations", params: {
      evaluation: { agent_id: agent.id, name: "Bare suite", scenarios: [ { prompt: "Hello", group: "Smoke" } ], criteria: [], run: false }
    }, as: :json

    assert_response :created
    evaluation = ActionAgent::Evaluation.find(JSON.parse(response.body).dig("evaluation", "id"))
    assert_equal 1, evaluation.scenarios.count
    assert_nil evaluation.latest_run
  end

  test "a run can be narrowed to a group and to models, and its results are readable" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    ActiveAgent::Evals::ScenarioParser.parse(CATALOG).each do |attrs|
      evaluation.scenarios.build(attrs.slice("key", "prompt", "group", "notes", "expectations", "position"))
    end
    evaluation.save!

    perform_enqueued_jobs do
      post "/activeagents/api/evaluations/#{evaluation.id}/run", params: { group: "Find records", models: [ "mock/alpha", "mock/beta" ] }, as: :json
    end

    assert_response :success
    run_id = JSON.parse(response.body).dig("run", "id")

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run_id}"

    assert_response :success
    run = JSON.parse(response.body)["run"]
    assert_equal "complete", run["status"]
    assert_equal %w[mock/alpha mock/beta], run["models"]
    assert_equal "Find records", run.dig("selection", "group")
    assert_equal 4, run["results"].size
    assert_equal %w[find_records_1 find_records_1 find_records_2 find_records_2], run["results"].map { |r| r["scenario_key"] }
    tool_miss = run["results"].find { |r| r["scenario_key"] == "find_records_2" }
    assert_equal "expected_tool_not_called", tool_miss["fault"]
    assert tool_miss["recommendation"].present?
    assert run["scores"]["_verdict"].present?
  end

  test "scenarios can be listed, replaced from a new paste, edited and deleted" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "a_1", group: "A", prompt: "First")
    evaluation.save!

    get "/activeagents/api/evaluations/#{evaluation.id}/scenarios"
    assert_response :success
    assert_equal [ "A" ], JSON.parse(response.body)["groups"]

    put "/activeagents/api/evaluations/#{evaluation.id}/scenarios", params: { scenarios_text: "# A\nFirst, reworded\n# B\nSecond" }, as: :json
    assert_response :success
    assert_equal %w[a_1 b_1], evaluation.scenarios.ordered.map(&:key)

    scenario = evaluation.scenarios.find_by!(key: "b_1")
    patch "/activeagents/api/evaluations/#{evaluation.id}/scenarios/#{scenario.id}", params: { scenario: { enabled: false, expectations: { tools: [ "fetch_url" ] } } }, as: :json
    assert_response :success
    assert_not scenario.reload.enabled
    assert_equal [ "fetch_url" ], scenario.expected_tools

    delete "/activeagents/api/evaluations/#{evaluation.id}/scenarios/#{scenario.id}"
    assert_response :no_content
    assert_equal [ "a_1" ], evaluation.scenarios.map(&:key)
  end

  test "replacing with an empty paste is refused" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "a_1", prompt: "First")
    evaluation.save!

    put "/activeagents/api/evaluations/#{evaluation.id}/scenarios", params: { scenarios_text: "   " }, as: :json

    assert_response :unprocessable_entity
    assert_equal 1, evaluation.scenarios.count
  end

  test "the index still serves a suite whose latest run is pending" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "a_1", prompt: "First")
    evaluation.save!
    evaluation.run_later!

    get "/activeagents/api/evaluations", params: { agent_id: agent.id }

    assert_response :success
    listed = JSON.parse(response.body)["evaluations"].first
    assert_equal "pending", listed.dig("latest_run", "status")
    assert_nil listed.dig("latest_run", "average_score")
  end

  test "a completed run renders as a self-contained HTML report page" do
    agent = create_agent
    evaluation = agent.evaluations.create!(
      name: "Report suite", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ],
      config: { "scenario_suite" => true }
    )
    scenario = evaluation.scenarios.create!(key: "s1", prompt: "Who changed the <biography>?", group: "blame", position: 0)
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    run.scenario_results.create!(
      scenario: scenario, model: "mock-model", provider: "mock", status: :passed, score: 1.0,
      scores: { "response_present" => 1.0 }, output: "<b>Alice</b> did.", duration_ms: 10
    )

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}/report"

    assert_response :success
    assert_match %r{text/html}, response.content_type
    assert_includes response.body, "<!doctype html>"
    assert_includes response.body, "Who changed the &lt;biography&gt;?"
    assert_includes response.body, "&lt;b&gt;Alice&lt;/b&gt; did."
    assert_includes response.body, "Report suite"
  end

  test "a generation-sampling run has no report page" do
    agent = create_agent
    evaluation = agent.evaluations.create!(
      name: "Sampling", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
    )
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}/report"

    assert_response :not_found
  end
end
