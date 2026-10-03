# frozen_string_literal: true

require "test_helper"

# Evaluation#merge_scenarios!: adding scenarios to a suite and updating the
# ones it names, without touching any scenario it was not given.
class EvaluationMergeScenariosTest < ActiveSupport::TestCase
  def setup
    ActionAgent::Agent.delete_all
    agent = ActionAgent::Agent.create!(name: "Support", slug: "support", provider: "mock", model: "mock-model")
    @evaluation = agent.evaluations.new(name: "Support questions", judge_kind: "rules", criteria: [])
    @evaluation.scenarios.build(key: "orders_1", group: "Orders", prompt: "Where is order ABC-123?", position: 0)
    @evaluation.scenarios.build(key: "orders_2", group: "Orders", prompt: "Which orders shipped late?", position: 1,
                                notes: "Lists each late order.", expectations: { "tools" => [ "find_orders" ] })
    @evaluation.scenarios.build(key: "billing_1", group: "Billing", prompt: "Why was I charged twice?", position: 2)
    @evaluation.save!
  end

  test "a key the merge was not given keeps its prompt, enabled flag, position and results" do
    untouched = @evaluation.scenarios.find_by!(key: "orders_2")
    untouched.update!(enabled: false)
    result = completed_run.scenario_results.create!(scenario: untouched, provider: "mock", model: "mock/alpha", status: :passed)
    before = untouched.reload.attributes

    @evaluation.merge_scenarios!([ { "key" => "orders_1", "prompt" => "Where is order XYZ-9?", "group" => "Orders" } ])

    assert_equal before, untouched.reload.attributes
    assert ActionAgent::EvaluationScenarioResult.exists?(result.id), "a scenario left out keeps its results"
    assert_equal 3, @evaluation.scenarios.count
  end

  test "a given existing key is updated in place and keeps its enabled flag and position" do
    scenario = @evaluation.scenarios.find_by!(key: "orders_2")
    scenario.update!(enabled: false)

    merged = @evaluation.merge_scenarios!([
      { "key" => "orders_2", "prompt" => "Which orders shipped after their promised date?", "group" => "Shipping",
        "notes" => "Names each late order.", "expectations" => { "contains" => [ "late" ] } }
    ])

    scenario.reload
    assert_equal({ added: [], updated: [ "orders_2" ], unchanged: [] }, merged)
    assert_equal "Which orders shipped after their promised date?", scenario.prompt
    assert_equal "Shipping", scenario.group
    assert_equal "Names each late order.", scenario.notes
    assert_equal({ "contains" => [ "late" ] }, scenario.expectations)
    assert_not scenario.enabled, "the merge keeps the flag the suite set"
    assert_equal 1, scenario.position
  end

  test "an existing key moves or changes its enabled flag only when the attributes say so" do
    @evaluation.merge_scenarios!([
      { "key" => "orders_1", "prompt" => "Where is order ABC-123?", "group" => "Orders", "position" => 9, "enabled" => false }
    ])

    scenario = @evaluation.scenarios.find_by!(key: "orders_1")
    assert_equal 9, scenario.position
    assert_not scenario.enabled
  end

  test "new keys are appended after the last position, in input order" do
    @evaluation.scenarios.find_by!(key: "billing_1").update!(position: 7)

    merged = @evaluation.merge_scenarios!([
      { "key" => "refunds_1", "prompt" => "Can I get a refund?", "group" => "Refunds" },
      { "key" => "orders_1", "prompt" => "Where is order ABC-123?", "group" => "Orders" },
      { "key" => "refunds_2", "prompt" => "How long does a refund take?", "group" => "Refunds" }
    ])

    assert_equal({ added: %w[refunds_1 refunds_2], updated: [], unchanged: [ "orders_1" ] }, merged)
    assert_equal %w[orders_1 orders_2 billing_1 refunds_1 refunds_2], @evaluation.scenarios.ordered.map(&:key)
    assert_equal [ 8, 9 ], @evaluation.scenarios.where(key: %w[refunds_1 refunds_2]).order(:position).pluck(:position)
    assert @evaluation.scenarios.where(key: %w[refunds_1 refunds_2]).all?(&:enabled)
  end

  test "merging the same paste twice adds it once and then changes nothing" do
    paste = [ { "key" => "refunds_1", "prompt" => "Can I get a refund?", "group" => "Refunds" } ]

    first = @evaluation.merge_scenarios!(paste)
    second = @evaluation.merge_scenarios!(paste)

    assert_equal [ "refunds_1" ], first[:added]
    assert_equal({ added: [], updated: [], unchanged: [ "refunds_1" ] }, second)
    assert_equal 4, @evaluation.scenarios.count
  end

  test "a merge that would pass the limit is refused whole" do
    error = assert_raises(ActionAgent::Evaluation::ScenarioLimitExceeded) do
      @evaluation.merge_scenarios!([
        { "key" => "orders_1", "prompt" => "Changed", "group" => "Orders" },
        { "key" => "refunds_1", "prompt" => "Can I get a refund?" },
        { "key" => "refunds_2", "prompt" => "How long does a refund take?" }
      ], limit: 4)
    end

    assert_match(/holds 3 and this merge adds 2/, error.message)
    assert_equal 3, @evaluation.scenarios.count
    assert_equal "Where is order ABC-123?", @evaluation.scenarios.find_by!(key: "orders_1").prompt
  end

  test "a merge that reaches the limit exactly is allowed" do
    @evaluation.merge_scenarios!([ { "key" => "refunds_1", "prompt" => "Can I get a refund?" } ], limit: 4)

    assert_equal 4, @evaluation.scenarios.count
  end

  test "a blank or repeated key is refused before anything is written" do
    assert_raises(ArgumentError) { @evaluation.merge_scenarios!([ { "key" => " ", "prompt" => "Anything" } ]) }
    error = assert_raises(ArgumentError) do
      @evaluation.merge_scenarios!([ { "key" => "x_1", "prompt" => "One" }, { "key" => "x_1", "prompt" => "Two" } ])
    end

    assert_match(/x_1/, error.message)
    assert_equal 3, @evaluation.scenarios.count
  end

  test "an invalid scenario rolls the whole merge back" do
    assert_raises(ActiveRecord::RecordInvalid) do
      @evaluation.merge_scenarios!([
        { "key" => "refunds_1", "prompt" => "Can I get a refund?" },
        { "key" => "orders_1", "prompt" => "Changed", "group" => "Orders" },
        { "key" => "refunds_2", "prompt" => "" }
      ])
    end

    assert_equal %w[billing_1 orders_1 orders_2], @evaluation.scenarios.pluck(:key).sort
    assert_equal "Where is order ABC-123?", @evaluation.scenarios.find_by!(key: "orders_1").prompt
  end

  private

  def completed_run
    @evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
  end
end
