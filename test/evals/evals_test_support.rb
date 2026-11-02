# frozen_string_literal: true

# Builders shared by the evaluation tests. Loaded by each test file after the
# dummy app's test_helper.
module EvalsTestSupport
  Scenario = ActiveAgent::Evals::Scenario
  Replay = ActiveAgent::Evals::Replay
  ModelSpec = ActiveAgent::Evals::ModelSpec

  def scenario(key = "s_1", prompt = "Who changed the shipping policy?", group: "history", **expectations)
    Scenario.from_hash({ "key" => key, "prompt" => prompt, "expectations" => expectations.transform_keys(&:to_s) }, group: group)
  end

  def spec(label, provider: "openai")
    ModelSpec.parse(label, default_provider: provider)
  end

  def replay(answer: "Alice changed it on Monday.", **attributes)
    Replay.new(answer: answer, **attributes)
  end

  # A judge whose completions come from a hash of `instructions fragment => reply`.
  def fake_judge(label: "judge", &block)
    ActiveAgent::Evals::Judge.new(label: label) { |instructions:, prompt:| block.call(instructions, prompt) }
  end

  # A judge that answers every call with `reply` and tallies the calls in
  # `calls` (a `Hash.new(0)`) under the Judge method that made them:
  # "score_task", "score_criterion", "recommend" or "verdict".
  def counting_judge(calls, reply: '{"score": 0.9, "recommendation": "Call the expected tool."}')
    fake_judge do |_instructions, prompt|
      calls[judge_call(prompt)] += 1
      reply
    end
  end

  # Which Judge method wrote `prompt`.
  def judge_call(prompt)
    if prompt.start_with?("Criterion:") then "score_criterion"
    elsif prompt.include?("Detected fault") then "recommend"
    elsif prompt.include?("Results per model") then "verdict"
    else "score_task"
    end
  end
end
