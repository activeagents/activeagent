# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsModelSpecTest < ActiveSupport::TestCase
  def parse(value, **options)
    ActiveAgent::Evals::ModelSpec.parse(value, default_provider: "openai", **options)
  end

  def test_a_provider_prefix_names_the_provider
    spec = parse("anthropic/claude-sonnet-5")

    assert_equal "anthropic", spec.provider
    assert_equal "claude-sonnet-5", spec.model
    assert_equal "anthropic/claude-sonnet-5", spec.label
  end

  def test_a_vendor_prefix_routes_through_openrouter_when_available
    spec = parse("meta-llama/llama-3.3-70b-instruct")

    assert_equal "openrouter", spec.provider
    assert_equal "meta-llama/llama-3.3-70b-instruct", spec.model
  end

  def test_a_vendor_prefix_stays_in_the_model_name_without_openrouter
    spec = parse("meta-llama/llama-3.3-70b-instruct", providers: %w[openai anthropic])

    assert_equal "openai", spec.provider
    assert_equal "meta-llama/llama-3.3-70b-instruct", spec.model
  end

  def test_an_explicit_openrouter_prefix_keeps_the_vendor_path_as_the_model
    spec = parse("openrouter/anthropic/claude-sonnet-4.5")

    assert_equal "openrouter", spec.provider
    assert_equal "anthropic/claude-sonnet-4.5", spec.model
  end

  def test_bare_names_infer_their_provider_from_the_family
    assert_equal "anthropic", parse("claude-haiku-4-5").provider
    assert_equal "openai", parse("gpt-5-mini").provider
    assert_equal "openai", parse("o3-mini").provider
    assert_equal "ollama", parse("qwen3:8b").provider
  end

  def test_an_inference_rule_for_a_provider_the_app_lacks_is_skipped
    assert_equal "openai", parse("qwen3:8b", providers: %w[openai anthropic]).provider
  end

  def test_an_unrecognised_name_runs_under_the_default_provider
    assert_equal "ollama", ActiveAgent::Evals::ModelSpec.parse("mistral", default_provider: "ollama").provider
  end

  def test_parse_all_drops_blanks_and_duplicates_and_accepts_a_comma_list
    specs = ActiveAgent::Evals::ModelSpec.parse_all(" gpt-5-mini , ,gpt-5-mini, qwen3:8b", default_provider: "openai")

    assert_equal [ "gpt-5-mini", "qwen3:8b" ], specs.map(&:label)
  end

  def test_a_blank_name_is_rejected
    assert_raises(ArgumentError) { parse("  ") }
  end

  def test_specs_compare_by_value
    assert_equal parse("gpt-5-mini"), parse("gpt-5-mini")
    assert_equal({ "label" => "gpt-5-mini", "provider" => "openai", "model" => "gpt-5-mini" }, parse("gpt-5-mini").to_h)
  end
end
