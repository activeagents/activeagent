# frozen_string_literal: true

# Builders shared by the evaluation tests. Loaded by each test file after the
# dummy app's test_helper.
module EvalsTestSupport
  Scenario = ActiveAgent::Evals::Scenario
  Replay = ActiveAgent::Evals::Replay
  ModelSpec = ActiveAgent::Evals::ModelSpec

  def scenario(key = "s_1", prompt = "Who changed the biography?", group: "blame", **expectations)
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
end
