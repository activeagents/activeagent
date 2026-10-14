# frozen_string_literal: true

require "test_helper"
require_relative "support/exploration_setup"

# The Scenarios page's generator: an exploration's candidates accepted into
# a set of a scenario catalog rather than into the project's evaluation.
class ExplorationScenarioSetAcceptTest < ActionDispatch::IntegrationTest
  include ExplorationSetup

  BASE = "/activeagents/api/explorations"

  def setup
    reset_exploration_records!
    ActionAgent::ScenarioCatalog.delete_all
    @project = create_explored_project!
    stub_runtime
    @catalog = ActionAgent::ScenarioCatalog.create!(key: "shop", name: "Shop", source_kind: "api")
    product = @catalog.products.create!(key: "assistant", name: "Assistant", project: @project)
    @set = product.sets.create!(key: "explored", name: "Explored")
  end

  def teardown
    ActionAgent.permission_checker = nil
  end

  def submit(candidates)
    post BASE, params: { project_id: @project.id, candidates: candidates }, as: :json
    JSON.parse(response.body).dig("exploration", "id")
  end

  test "accepted candidates become the set's scenarios, and accepting again updates them" do
    id = submit([ candidate("Where is order A-17?", tools: [ "lookup_order" ], rubric: "Gives the status."),
                  candidate("Cancel A-17") ])

    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 1, 2 ], scenario_set_id: @set.id }, as: :json
    body = JSON.parse(response.body)
    assert_response :success, body.inspect
    assert_equal [ "x#{id}_1", "x#{id}_2" ], body.dig("accepted", "added")
    assert_equal [ "explored", "shop" ], [ body.dig("scenario_set", "key"), body.dig("scenario_set", "catalog", "key") ]
    assert_equal [ "accepted", "x#{id}_1", @set.id ], body["candidates"].first.values_at("state", "scenario_key", "scenario_set_id")

    scenario = @set.scenarios.find_by!(key: "x#{id}_1")
    assert_equal [ "Where is order A-17?", "Gives the status.", { "tools" => [ "lookup_order" ] }, [ "explored" ] ],
      [ scenario.prompt, scenario.notes, scenario.expectations, scenario.tags ]
    assert_includes @catalog.reload.document, "Where is order A-17?"
    assert_equal 0, @project.evaluation.scenarios.count, "the project's evaluation is left alone"

    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 1 ], scenario_set_id: @set.id,
                                           edits: { "1" => { rubric: "Gives the status and carrier." } } }, as: :json
    body = JSON.parse(response.body)
    assert_response :success, body.inspect
    assert_equal [ "x#{id}_1" ], body.dig("accepted", "updated")
    assert_equal "Gives the status and carrier.", scenario.reload.notes
  end

  test "a key the set already holds from elsewhere, a rejected candidate and another owner's set are refused" do
    id = submit([ candidate("Where is order A-17?"), candidate("Cancel A-17") ])
    @set.scenarios.create!(key: "x#{id}_1", prompt: "Written by hand")

    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 1 ], scenario_set_id: @set.id }, as: :json
    assert_response :unprocessable_entity
    assert_match(/already holds/, JSON.parse(response.body).dig("problems", "1"))

    patch "#{BASE}/#{id}/candidates/2", params: { state: "rejected" }, as: :json
    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 2 ], scenario_set_id: @set.id }, as: :json
    assert_response :unprocessable_entity
    assert_equal [ "Written by hand" ], @set.scenarios.pluck(:prompt)

    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 1 ], scenario_set_id: 0 }, as: :json
    assert_response :not_found
  end

  test "accepting into a set needs :replace_scenarios on its catalog" do
    id = submit([ candidate("Where is order A-17?") ])
    asked = []
    ActionAgent.permission_checker = lambda do |_user, action, subject|
      asked << [ action, subject.class.name ]
      false
    end

    post "#{BASE}/#{id}/accept", params: { candidate_ids: [ 1 ], scenario_set_id: @set.id }, as: :json
    assert_response :forbidden
    assert_equal [ [ :replace_scenarios, "ActionAgent::ScenarioCatalog" ] ], asked
    assert_equal 0, @set.scenarios.count
  end
end
