# frozen_string_literal: true

require "test_helper"

# The scenario-suite half of the evaluations API: creating an evaluation
# from pasted messages, managing its scenarios, running a selection under
# chosen models, and reading a run's per-scenario results.
class ActionAgentScenarioEvaluationsApiTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
  end

  def teardown
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
    ActionAgent.execution_enabled = true
  end

  def create_agent(**attributes)
    ActionAgent::Agent.create!({ name: "Assistant", provider: "mock", model: "mock-model", instructions: "Answer from data." }.merge(attributes))
  end

  def create_suite(agent, prompt: "First")
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "a_1", prompt: prompt)
    evaluation.save!
    evaluation
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

  # An empty criteria list is indistinguishable from an omitted one through
  # the API, so the suite gets the rule-based defaults; only the model layer
  # accepts a suite scored on its scenarios' expectations alone.
  test "a suite posted with an empty criteria list gets the default rule criteria and no run when told not to" do
    agent = create_agent

    post "/activeagents/api/evaluations", params: {
      evaluation: { agent_id: agent.id, name: "Bare suite", scenarios: [ { prompt: "Hello", group: "Smoke" } ], criteria: [], run: false }
    }, as: :json

    assert_response :created
    evaluation = ActionAgent::Evaluation.find(JSON.parse(response.body).dig("evaluation", "id"))
    assert_equal 1, evaluation.scenarios.count
    assert_equal %w[response_present response_length latency token_budget], evaluation.criteria.map { |criterion| criterion["key"] }
    assert_nil evaluation.latest_run
  end

  test "running a suite is agent execution: refused when the dashboard's execution is off" do
    evaluation = create_suite(create_agent)
    ActionAgent.execution_enabled = false

    post "/activeagents/api/evaluations/#{evaluation.id}/run", params: { models: [ "mock/alpha" ] }, as: :json

    assert_response :forbidden
    assert_nil evaluation.latest_run
    assert_no_enqueued_jobs only: ActionAgent::EvaluationRunJob
  end

  test "creating a suite that runs is subject to the host's execution quota; creating one that does not run is not" do
    agent = create_agent
    ActionAgent.quota_checker = ->(_owner, kind) { "Out of runs" if kind == :execution }

    post "/activeagents/api/evaluations", params: { evaluation: { agent_id: agent.id, name: "Catalog", scenarios_text: "First" } }, as: :json
    assert_response :payment_required
    assert_equal 0, agent.evaluations.count

    post "/activeagents/api/evaluations", params: { evaluation: { agent_id: agent.id, name: "Catalog", scenarios_text: "First", run: false } }, as: :json
    assert_response :created
  end

  test "a generation-sampling evaluation is not gated: it scores recorded data rather than executing the agent" do
    agent = create_agent
    ActionAgent.execution_enabled = false

    post "/activeagents/api/evaluations", params: { evaluation: { agent_id: agent.id, name: "Sampled" } }, as: :json

    assert_response :created
  end

  test "an observed agent's suite cannot be run" do
    evaluation = create_suite(create_agent(status: :observed))

    post "/activeagents/api/evaluations/#{evaluation.id}/run", as: :json

    assert_response :unprocessable_entity
    assert_match(/read-only/, JSON.parse(response.body)["error"])
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
end
