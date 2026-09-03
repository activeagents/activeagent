# frozen_string_literal: true

require "test_helper"

class ActionAgentModelSpecTest < ActiveSupport::TestCase
  def parse(value, default_provider: "openai")
    ActionAgent::ModelSpec.parse(value, default_provider: default_provider)
  end

  test "a provider prefix names the provider" do
    spec = parse("anthropic/claude-sonnet-5")

    assert_equal "anthropic", spec.provider
    assert_equal "claude-sonnet-5", spec.model
    assert_equal "anthropic/claude-sonnet-5", spec.label
  end

  test "a vendor prefix that is not a provider routes through openrouter with the full name" do
    spec = parse("meta-llama/llama-3.3-70b-instruct")

    assert_equal "openrouter", spec.provider
    assert_equal "meta-llama/llama-3.3-70b-instruct", spec.model
  end

  test "an explicit openrouter prefix keeps the vendor path as the model" do
    spec = parse("openrouter/anthropic/claude-sonnet-4.5")

    assert_equal "openrouter", spec.provider
    assert_equal "anthropic/claude-sonnet-4.5", spec.model
  end

  test "bare names infer their provider from the family" do
    assert_equal "anthropic", parse("claude-haiku-4-5").provider
    assert_equal "openai", parse("gpt-5-mini").provider
    assert_equal "openai", parse("o3-mini").provider
    assert_equal "ollama", parse("qwen3:8b").provider
  end

  test "an unrecognised name runs under the agent's provider" do
    assert_equal "ollama", parse("mistral", default_provider: "ollama").provider
  end

  test "parse_all drops blanks and duplicates" do
    specs = ActionAgent::ModelSpec.parse_all([ " gpt-5-mini ", "", "gpt-5-mini", "qwen3:8b" ], default_provider: "openai")

    assert_equal [ "gpt-5-mini", "qwen3:8b" ], specs.map(&:label)
  end

  test "a blank name is rejected" do
    assert_raises(ArgumentError) { parse("  ") }
  end
end
