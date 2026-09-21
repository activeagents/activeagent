# frozen_string_literal: true

require "test_helper"

# Generation-sampling evaluations (Evaluation#run! without scenarios) score
# llm_judge criteria through EvaluationRunnerService's own judge, not through
# ActiveAgent::Evals::Judge. Its score parsing has to agree with the gem's.
class ActionAgentEvaluationRunnerServiceTest < ActiveSupport::TestCase
  def parse(content)
    ActionAgent::EvaluationRunnerService.new(nil).send(:parse_judge_score, content)
  end

  # Regression: a digit-only regex read the "9" of 9e-2 and clamped a 0.09
  # score to a perfect 1.0, passing outputs the judge had just failed.
  test "judge scores are JSON numbers, including exponent notation" do
    { '{"score": 9e-2}' => 0.09, '{"score": 5e-1}' => 0.5, '{"score": 0.7}' => 0.7,
      '{"score": -0.2}' => 0.0, '{"score": 2}' => 1.0,
      "```json\n{\"score\": 9e-2}\n```" => 0.09 }.each do |content, expected|
      assert_in_delta expected, parse(content), 0.0001, content
    end
  end

  test "the judge class is built once per service instance" do
    ActionAgent::Agent.delete_all
    agent = ActionAgent::Agent.create!(name: "Judged", provider: "openai", model: "gpt-4o-mini")
    evaluation = agent.evaluations.create!(name: "Quality", judge_kind: "llm", judge_model: "gpt-4o-mini",
                                           criteria: [ { "key" => "quality", "type" => "llm_judge" } ])
    service = ActionAgent::EvaluationRunnerService.new(evaluation)
    resolved = 0

    service.stub(:judge_provider, -> { resolved += 1; :openai }) do
      assert_same service.send(:judge_class), service.send(:judge_class)
    end

    assert_equal 1, resolved
  end

  test "malformed or non-numeric judge scores are unscorable" do
    [ '{"score": "0.9"}', '{"score": true}', '{"score": null}', '{"score": {}}',
      '{"score": 0.9oops}', '{"score": 1e999}', '{"score": NaN}', "{}", "no json here", nil ].each do |content|
      assert_nil parse(content), content.inspect
    end
  end

  # --- cohorts and spend ------------------------------------------------------

  def sampled_agent
    ActionAgent::Agent.delete_all
    ActionAgent::Agent.create!(name: "Sampled", provider: "openai", model: "gpt-4o-mini")
  end

  def record_generation(agent, content: "A sufficiently long answer with plenty of substance in it.", model: "gpt-4o-mini",
                        provider: "openai", input_tokens: 20, output_tokens: 25, duration: 0.5)
    context = ActionAgent::AgentContext.create!(contextable: agent, agent_name: "SampledAgent", action_name: "respond")
    context.generations.create!(
      content: content, model: model, provider: provider, input_tokens: input_tokens, output_tokens: output_tokens,
      duration_seconds: duration, finish_reason: "stop"
    )
  end

  test "records a per-model cohort summary of the sampled generations, priced as the agent's cost" do
    agent = sampled_agent
    record_generation(agent)
    record_generation(agent, content: "short", output_tokens: 2000, duration: 20)

    run = agent.evaluations.create!(
      name: "Rules", judge_kind: "rules",
      criteria: [
        { "key" => "response_present", "type" => "response_present", "config" => {} },
        { "key" => "token_budget", "type" => "token_budget", "config" => { "output_tokens" => 1000 } }
      ]
    ).run!

    cohorts = run.scores["_cohorts"]
    assert_equal [ "gpt-4o-mini" ], cohorts.keys
    cohort = cohorts["gpt-4o-mini"]
    assert_equal 2, cohort["samples"]
    # Only the first generation clears both criteria; "short" blows the budget.
    assert_equal 1, cohort["passed"]
    assert_equal "openai", cohort["provider"]
    assert_equal 40, cohort["input_tokens"]
    assert_equal 2025, cohort["output_tokens"]
    # (500ms + 20000ms) / 2
    assert_equal 10_250, cohort["avg_duration_ms"]
    assert_in_delta ActionAgent::ModelPricing.estimate(model: "gpt-4o-mini", input_tokens: 40, output_tokens: 2025), cohort["cost"], 1e-9
    # No judge was asked, so the run records no judge spend at all.
    assert_nil run.scores["_judge_usage"]
    # Metadata never leaks into the criterion average: (1.0 + 0.75) / 2.
    assert_in_delta 0.875, run.average_score, 0.001
  end

  # A stand-in for the judge agent class: answers every prompt with the JSON
  # the call expects and reports the tokens it "spent", so the meter has
  # something to price.
  JudgeReply = Struct.new(:content, :input_tokens, :output_tokens, :model) do
    def message = Struct.new(:content).new(content)
    def usage = Struct.new(:input_tokens, :output_tokens).new(input_tokens, output_tokens)
    def generate_now = self
  end

  def fake_judge(model: "claude-opus-5")
    Class.new do
      define_singleton_method(:prompt) do |message:, instructions:|
        content = if instructions.include?("comparing model cohorts")
          { winner: "gpt-4o-mini", rationale: "Cheaper and no worse." }.to_json
        else
          { score: 0.9 }.to_json
        end
        JudgeReply.new(content, 300, 12, model)
      end
    end
  end

  test "meters the judge's calls apart from the agent's cost, by what each call was for" do
    agent = sampled_agent
    record_generation(agent)
    record_generation(agent, model: "gpt-4o", input_tokens: 50, output_tokens: 30)

    evaluation = agent.evaluations.create!(
      name: "Judged comparison", judge_kind: "llm", judge_model: "claude-opus-5",
      criteria: [ { "key" => "quality", "type" => "llm_judge", "config" => { "prompt" => "Is the answer useful?" } } ],
      config: { "compare_models" => [ "gpt-4o-mini", "gpt-4o" ] }
    )
    service = ActionAgent::EvaluationRunnerService.new(evaluation)
    run = service.stub(:judge_provider, :anthropic) do
      service.stub(:judge_class, fake_judge) { service.call }
    end

    assert run.complete?
    judge = run.scores["_judge_usage"]
    # One score per sampled generation, then the verdict across the cohorts.
    assert_equal({ "score" => 2, "verdict" => 1 }, judge["by_kind"])
    assert_equal 3, judge["calls"]
    assert_equal 900, judge["input_tokens"]
    assert_equal 36, judge["output_tokens"]
    assert_equal "claude-opus-5", judge["model"]
    assert_in_delta ActionAgent::ModelPricing.estimate(model: "claude-opus-5", input_tokens: 900, output_tokens: 36), judge["cost"], 1e-9
    assert_equal "gpt-4o-mini", run.scores.dig("_verdict", "winner")

    # The cohorts carry the agent's side, untouched by what the judge spent.
    assert_equal %w[gpt-4o gpt-4o-mini], run.scores["_cohorts"].keys.sort
    assert_in_delta ActionAgent::ModelPricing.estimate(model: "gpt-4o", input_tokens: 50, output_tokens: 30),
                    run.scores.dig("_cohorts", "gpt-4o", "cost"), 1e-9

    usage = run.usage
    assert_equal 2, usage[:samples]
    # Each cohort's cost is rounded to six places and so is their sum.
    assert_in_delta run.scores.dig("_cohorts", "gpt-4o", "cost") + run.scores.dig("_cohorts", "gpt-4o-mini", "cost"), usage[:cost], 1e-6
    assert_in_delta usage[:cost] / 2, usage[:per_interaction], 1e-6
    assert_equal judge, usage[:judge]
  end
end
