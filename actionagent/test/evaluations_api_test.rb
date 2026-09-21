# frozen_string_literal: true

require "test_helper"

# EvaluationRunnerService records the failure on the run and re-raises;
# letting that escape turned a persisted evaluation into an HTML 500 that
# the form displayed as a JSON parse error, and a resubmit then failed on
# the taken name (#381).
class EvaluationsApiTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
  end

  test "an evaluation whose run raises is still returned with its failed run" do
    exploding = ->(_evaluation) { raise "Judge-defined KPIs need provider credentials" }

    ActionAgent::EvaluationRunnerService.stub(:call, exploding) do
      post "/activeagents/api/evaluations", params: {
        evaluation: { agent_id: @agent.id, name: "KPIs", judge_kind: "judge_defined" }
      }
    end

    assert_response :created
    body = JSON.parse(response.body)
    latest = body.dig("evaluation", "latest_run")
    assert_equal "failed", latest["status"]
    assert_match(/provider credentials/, latest["error_message"])

    ActionAgent::EvaluationRunnerService.stub(:call, exploding) do
      post "/activeagents/api/evaluations/#{body.dig('evaluation', 'id')}/run"
    end

    assert_response :success
    assert_equal "failed", JSON.parse(response.body).dig("run", "status")
  end

  # The runs list numbers runs from the oldest, and the index carries the
  # run before the latest so a row can say "+3 passed vs #2" without a
  # request per evaluation.
  test "runs are numbered oldest-first and the list carries the run before the latest" do
    record_generations(@agent, 2)

    post "/activeagents/api/evaluations", params: { evaluation: { agent_id: @agent.id, name: "Numbered" } }, as: :json
    assert_response :created
    body = JSON.parse(response.body)
    evaluation_id = body.dig("evaluation", "id")
    assert_equal 1, body.dig("evaluation", "run_count")
    assert_equal 1, body.dig("evaluation", "latest_run", "number")
    assert_nil body.dig("evaluation", "previous_run")

    post "/activeagents/api/evaluations/#{evaluation_id}/run"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body.dig("run", "number")
    assert_equal 2, body.dig("evaluation", "run_count")
    assert_equal 2, body.dig("evaluation", "latest_run", "number")
    assert_equal 1, body.dig("evaluation", "previous_run", "number")

    get "/activeagents/api/evaluations"
    assert_response :success
    evaluation = JSON.parse(response.body)["evaluations"].find { |entry| entry["id"] == evaluation_id }
    assert_equal 2, evaluation["run_count"]
    assert_equal 2, evaluation.dig("latest_run", "number")
    assert_equal 1, evaluation.dig("previous_run", "number")
    assert_equal 2, evaluation.dig("previous_run", "samples_evaluated")
    refute evaluation["previous_run"].key?("scores"), "the previous run is a summary, not a full payload"

    get "/activeagents/api/evaluations/#{evaluation_id}"
    assert_response :success
    runs = JSON.parse(response.body).dig("evaluation", "runs")
    assert_equal [ 2, 1 ], runs.map { |run| run["number"] }
    # A sampling run summarizes its cohorts and prices them as the agent's
    # operating cost; it asked no judge, so it records no judge spend.
    cohort = runs.first.dig("scores", "_cohorts", "gpt-4o-mini")
    assert_equal 2, cohort["samples"]
    assert_equal 2, cohort["passed"]
    assert_equal 2, runs.first.dig("usage", "samples")
    assert_in_delta cohort["cost"], runs.first.dig("usage", "cost"), 1e-9
    assert_nil runs.first.dig("usage", "judge")
  end

  private

  def record_generations(agent, count)
    context = ActionAgent::AgentContext.create!(contextable: agent, agent_name: "SupportAgent", action_name: "respond")
    count.times do |index|
      context.generations.create!(
        content: "A sufficiently long answer number #{index} with enough substance to pass the length rule.",
        model: "gpt-4o-mini", provider: "openai", input_tokens: 120, output_tokens: 40, duration_seconds: 0.8,
        finish_reason: "stop"
      )
    end
  end
end
