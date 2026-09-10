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

  test "malformed or non-numeric judge scores are unscorable" do
    [ '{"score": "0.9"}', '{"score": true}', '{"score": null}', '{"score": {}}',
      '{"score": 0.9oops}', '{"score": 1e999}', '{"score": NaN}', "{}", "no json here", nil ].each do |content|
      assert_nil parse(content), content.inspect
    end
  end
end
