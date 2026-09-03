# frozen_string_literal: true

# The evaluation core runs without Rails: this helper loads only the gem.
# `bin/test` at the repository root requires the dummy app's test_helper first;
# both paths work because everything here is idempotent.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "activeagents/evals"
require "minitest/autorun"

module EvalsTestSupport
  Scenario = ActiveAgents::Evals::Scenario
  Replay = ActiveAgents::Evals::Replay
  ModelSpec = ActiveAgents::Evals::ModelSpec

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
    ActiveAgents::Evals::Judge.new(label: label) { |instructions:, prompt:| block.call(instructions, prompt) }
  end
end
