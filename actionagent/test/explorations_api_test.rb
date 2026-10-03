# frozen_string_literal: true

require "test_helper"
require_relative "support/exploration_setup"

# Explorations over the dashboard's JSON API: submitting candidates, reading
# them for review, editing and rejecting them, accepting them into the
# project's evaluation under :replace_scenarios, and stopping a walk.
class ExplorationsApiTest < ActionDispatch::IntegrationTest
  include ExplorationSetup

  BASE = "/activeagents/api/explorations"

  def setup
    reset_exploration_records!
    @project = create_explored_project!
    stub_runtime
  end

  def teardown
    ActionAgent.permission_checker = nil
    ActionAgent.exploration_preselect_limit = nil
    ActionAgent.usage_resolver = nil
    ActionAgent.multi_tenant = false
    ActionAgent.account_class = nil
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.scenario_evaluation_adapter_resolver = nil
  end

  def submit(candidates, target = { project_id: @project.id })
    post BASE, params: target.merge(candidates: candidates), as: :json
    JSON.parse(response.body)
  end

  test "submitting stores an external exploration in review, with each candidate's verdict" do
    body = submit([ candidate("Where is order A-17?", tools: [ "lookup_order" ], rubric: "Gives the status."),
                    candidate("Refund A-17", tools: [ "refund_order" ]) ])

    assert_response :created, body.inspect
    assert_equal [ "external", "review", @project.id ], body["exploration"].values_at("source", "status", "project_id")
    assert_equal %w[answerable needs_tool], body["candidates"].map { |row| row["verdict"] }
    assert_equal [ "refund_order" ], body["candidates"].second["missing_tools"]
    assert_equal({ "id" => @project.id, "name" => "Shop" }, body["project"])
    assert_equal({ "id" => @project.evaluation.id, "name" => @project.evaluation.name, "enabled_scenario_count" => 0,
                   "model_count" => 1 }, body["evaluation"])
    assert_nil body["preselect_limit"]
    assert_nil body["runs_remaining"]

    get BASE, params: { project_id: @project.id }
    assert_equal [ body.dig("exploration", "id") ], JSON.parse(response.body)["explorations"].map { |row| row["id"] }
  end

  test "submitting for an evaluation, and a submission naming neither or an invalid candidate" do
    evaluation = @project.evaluation
    body = submit([ candidate("Pay for A-17 with #{SECRET}") ], { evaluation_id: evaluation.id })
    assert_response :created
    assert_equal [ @project.id, evaluation.id ], body["exploration"].values_at("project_id", "evaluation_id")
    assert_equal "Pay for A-17 with [REDACTED]", body["candidates"].sole["prompt"]

    submit([ candidate("Hello") ], {})
    assert_response :bad_request

    body = submit([ { prompt: "" } ])
    assert_response :unprocessable_entity
    assert_match(/no prompt/, body["error"])

    submit([ candidate("Hello") ], { evaluation_id: 0 })
    assert_response :not_found
    assert_equal 1, ActionAgent::Exploration.count
  end

  test "an observed agent's evaluation is refused unless a host adapter replays it" do
    agent = ActionAgent::Agent.create!(name: "Reported", provider: "mock", model: "mock-model", status: :observed)
    evaluation = agent.evaluations.create!(name: "Reported suite", judge_kind: "rules",
      criteria: [ { "key" => "answered", "type" => "response_present", "config" => {} } ])

    body = submit([ candidate("Hello") ], { evaluation_id: evaluation.id })
    assert_response :unprocessable_entity
    assert_match(/read-only/, body["error"])
    assert_equal 0, ActionAgent::Exploration.count

    ActionAgent.scenario_evaluation_adapter_resolver = ->(_evaluation) { ->(**) { } }
    submit([ candidate("Hello") ], { evaluation_id: evaluation.id })
    assert_response :created
  end

  test "show carries the preselect limit the host sets for the owner, and its runs remaining" do
    ActionAgent.exploration_preselect_limit = ->(_owner) { 10 }
    ActionAgent.usage_resolver = ->(_owner) { { runs_used: 90, runs_limit: 100, runs_remaining: 10, can_run: true } }
    id = submit([ candidate("Hello") ]).dig("exploration", "id")

    get "#{BASE}/#{id}"

    body = JSON.parse(response.body)
    assert_equal [ 10, 10 ], body.values_at("preselect_limit", "runs_remaining")

    ActionAgent.exploration_preselect_limit = ->(_owner) { raise "plan lookup failed" }
    get "#{BASE}/#{id}"
    assert_nil JSON.parse(response.body)["preselect_limit"]
  end

  test "a candidate is edited, rejected and reconsidered" do
    id = submit([ candidate("Where is order A-17?", tools: [ "lookup_order" ]) ]).dig("exploration", "id")

    patch "#{BASE}/#{id}/candidates/1", params: { rubric: "Gives the carrier", tools: [ "track_parcel" ] }, as: :json
    body = JSON.parse(response.body)
    assert_response :success, body.inspect
    assert_equal [ "edited", "Gives the carrier", "needs_tool" ], body["candidate"].values_at("state", "notes", "verdict")

    patch "#{BASE}/#{id}/candidates/1", params: { state: "rejected" }, as: :json
    assert_equal [ "rejected", "closed" ], [ JSON.parse(response.body).dig("candidate", "state"),
                                             JSON.parse(response.body).dig("exploration", "status") ]

    patch "#{BASE}/#{id}/candidates/1", params: { state: "accepted" }, as: :json
    assert_response :unprocessable_entity

    patch "#{BASE}/#{id}/candidates/5", params: { prompt: "x" }, as: :json
    assert_response :not_found
  end

  test "accepting needs :replace_scenarios, asked about the evaluation, and a refusal writes nothing" do
    id = submit([ candidate("Where is order A-17?", rubric: "Gives the status.") ]).dig("exploration", "id")
    asked = []
    ActionAgent.permission_checker = lambda do |_user, action, subject|
      asked << [ action, subject.class.name ]
      false
    end

    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 1 ] }, as: :json

    assert_response :forbidden
    assert_equal [ "forbidden", "replace_scenarios" ], JSON.parse(response.body).values_at("code", "permission")
    assert_equal [ [ :replace_scenarios, "ActionAgent::Evaluation" ] ], asked
    assert_equal 0, @project.evaluation.scenarios.count

    ActionAgent.permission_checker = ->(_user, action, _subject) { action == :replace_scenarios }
    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 1 ], edits: { "1" => { rubric: "Gives the status and carrier." } } },
      as: :json

    body = JSON.parse(response.body)
    assert_response :success, body.inspect
    assert_equal [ "x#{id}_1" ], body.dig("accepted", "added")
    assert_equal 1, body.dig("evaluation", "enabled_scenario_count")
    assert_equal [ "accepted", "x#{id}_1" ], body["candidates"].sole.values_at("state", "scenario_key")
    assert_equal "Gives the status and carrier.", @project.evaluation.scenarios.sole.notes
  end

  test "a project's first accept asks about the exploration, since the evaluation does not exist yet" do
    @project.evaluation.destroy!
    id = submit([ candidate("Where is order A-17?") ]).dig("exploration", "id")
    asked = []
    ActionAgent.permission_checker = ->(_user, action, subject) { asked << [ action, subject.class.name ]; true }

    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 1 ] }, as: :json

    assert_response :success
    assert_equal [ [ :replace_scenarios, "ActionAgent::Exploration" ] ], asked
    assert_equal [ "x#{id}_1" ], @project.reload.evaluation.scenarios.pluck(:key)
  end

  test "a refused accept answers with each candidate's problem" do
    id = submit([ candidate("Where is order A-17?", contains: [ "a; b" ]) ]).dig("exploration", "id")

    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 1 ] }, as: :json

    assert_response :unprocessable_entity
    assert_match(/semicolon/, JSON.parse(response.body).dig("problems", "1"))
    assert_equal 0, @project.evaluation.scenarios.count
  end

  test "stopping keeps a running exploration's candidates for review, and answers 409 once it stopped" do
    exploration = ActionAgent::Exploration.build_for(project: @project, source: "explorer", status: "running",
      budget: { "minutes" => 15, "steps" => 150 }, usage: { "minutes" => 3, "steps" => 40 })
    exploration.save_with_candidates!([ candidate("Where is order A-17?") ])

    post "#{BASE}/#{exploration.id}/stop", as: :json

    body = JSON.parse(response.body)
    assert_response :success
    assert_equal [ "review", "stopped" ], body["exploration"].values_at("status", "stop_reason")
    assert_equal [ { "minutes" => 15, "steps" => 150 }, { "minutes" => 3, "steps" => 40 } ],
      body["exploration"].values_at("budget", "usage")
    assert_equal 1, body["candidates"].size

    post "#{BASE}/#{exploration.id}/stop", as: :json
    assert_response :conflict
  end

  test "another owner's exploration is a 404, and lists show only the caller's" do
    ActionAgent.multi_tenant = true
    ActionAgent.account_class = "ExplorationTestAccount"
    mine = ExplorationTestAccount.create!(name: "mine")
    theirs = ExplorationTestAccount.create!(name: "theirs")
    @project.update_columns(account_id: theirs.id)
    other = ActionAgent::Exploration.build_for(project: @project.reload, source: "external", status: "review")
    other.save_with_candidates!([ candidate("Where is order A-17?") ])
    ActionAgent.current_account_resolver = ->(_controller) { mine }

    get "#{BASE}/#{other.id}"
    assert_response :not_found
    patch "#{BASE}/#{other.id}/candidates/1", params: { state: "rejected" }, as: :json
    assert_response :not_found
    post "#{BASE}/#{other.id}/accept", params: { candidate_ids: [ 1 ] }, as: :json
    assert_response :not_found
    post "#{BASE}/#{other.id}/stop", as: :json
    assert_response :not_found
    submit([ candidate("Hello") ])
    assert_response :not_found

    get BASE
    assert_equal [], JSON.parse(response.body)["explorations"]
    assert_equal "proposed", other.reload.candidates.sole["state"]
  end
end
