# frozen_string_literal: true

require "test_helper"

# The dashboard's model pickers name each model the way a scenario run reads
# it, with a JavaScript copy of ActiveAgent::Evals::ModelSpec.parse. These
# cases are shared with actionagent/frontend/test/modelOptions.test.mjs, which
# runs the same fixture through that copy.
class ModelPickerNamesTest < ActiveSupport::TestCase
  CASES = JSON.parse(File.read(File.expand_path("fixtures/model_spec_cases.json", __dir__)))
  DEFAULT_PROVIDER = "agent-default"

  test "the fixture resolves names against the providers a scenario run does" do
    assert_equal ActionAgent::ScenarioEvaluationRunner::CANDIDATE_PROVIDERS, CASES["providers"]
  end

  test "each name resolves to the provider and model the fixture expects" do
    CASES["names"].each do |example|
      spec = parse(example["name"])

      assert_equal [ example["provider"] || DEFAULT_PROVIDER, example["model"] ], [ spec.provider, spec.model ],
                   "#{example['name'].inspect} resolved differently"
    end
  end

  test "each picker name runs the id on the provider that listed it" do
    CASES["qualified"].each do |example|
      spec = parse(example["name"])

      assert_equal [ example["provider"], example["id"] ], [ spec.provider, spec.model ],
                   "#{example['name'].inspect} does not run #{example['provider']}'s #{example['id'].inspect}"
    end
  end

  private

  def parse(name)
    ActiveAgent::Evals::ModelSpec.parse(name, default_provider: DEFAULT_PROVIDER, providers: CASES["providers"])
  end
end
