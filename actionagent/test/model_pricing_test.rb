# frozen_string_literal: true

require "test_helper"
require_relative "support/ruby_llm_constant"

# Rates per model, looked up under the provider the model ran on, from
# RubyLLM's registry when the install has it and from the static tables
# otherwise — each saying where it came from.
class ActionAgentModelPricingTest < ActiveSupport::TestCase
  include RubyLLMConstant

  Pricing = ActionAgent::ModelPricing

  setup { Pricing.reset! }
  teardown { Pricing.reset! }

  # A stand-in registry: `find(id, provider:)` as RubyLLM 2 answers, with a
  # few models the static tables would price differently.
  class Registry
    VERSION = "test-registry"
    Tokens = Struct.new(:input, :output)
    Info = Struct.new(:id, :provider, :tokens) do
      def pricing = Struct.new(:text_tokens).new(tokens)
    end
    MODELS = {
      [ "gpt-5.5", nil ] => Info.new("gpt-5.5", "openai", Tokens.new(5.0, 30.0)),
      [ "gpt-5.5", "openrouter" ] => Info.new("openai/gpt-5.5", "openrouter", Tokens.new(5.0, 30.0)),
      [ "openai/gpt-5.5", "openrouter" ] => Info.new("openai/gpt-5.5", "openrouter", Tokens.new(5.0, 30.0)),
      [ "claude-sonnet-5", nil ] => Info.new("claude-sonnet-5", "anthropic", Tokens.new(2.0, 10.0)),
      [ "claude-sonnet-4-5", "anthropic" ] => Info.new("claude-sonnet-4-5", "anthropic", Tokens.new(3.0, 15.0)),
      [ "gpt-4o-mini", nil ] => Info.new("gpt-4o-mini", "openai", Tokens.new(0.15, 0.6)),
      # Ollama Cloud lists DeepSeek's model at its own price.
      [ "gpt-oss:120b", "ollama_cloud" ] => Info.new("gpt-oss:120b", "ollama_cloud", Tokens.new(0.15, 0.6)),
      [ "deepseek-v4-flash", "ollama_cloud" ] => Info.new("deepseek-v4-flash", "ollama_cloud", Tokens.new(0.22, 0.66)),
      [ "deepseek-v4-flash", "deepseek" ] => Info.new("deepseek-v4-flash", "deepseek", Tokens.new(0.15, 0.6)),
      [ "deepseek-v4-flash", nil ] => Info.new("deepseek-v4-flash", "deepseek", Tokens.new(0.15, 0.6))
    }.freeze

    def self.lookups = (@lookups ||= [])

    def self.models = new

    def find(id, provider: nil)
      self.class.lookups << [ id, provider ]
      MODELS[[ id, provider ]] || raise("Unknown model: #{id}")
    end
  end

  def with_registry(&)
    Registry.lookups.clear
    with_ruby_llm_constant(Registry, &)
  end

  test "a model is priced from the registry under the provider it ran on" do
    with_registry do
      detail = Pricing.rate_detail("gpt-5.5", provider: "openrouter")
      assert_equal({ input: 5.0, output: 30.0, source: "catalog" }, detail)
      assert_equal [ "gpt-5.5", "openrouter" ], Registry.lookups.first

      assert_in_delta (2_328 * 5.0 + 423 * 30.0) / 1_000_000, Pricing.estimate(model: "gpt-5.5", provider: "openrouter", input_tokens: 2_328, output_tokens: 423), 1e-12
    end
  end

  test "a gateway or vendor prefix is stripped and the dots and dashes of a name are tried both ways" do
    with_registry do
      assert_equal 5.0, Pricing.rate_detail("openrouter/openai/gpt-5.5")[:input], "the openrouter prefix names the provider"
      assert_equal 3.0, Pricing.rate_detail("anthropic/claude-sonnet-4.5", provider: "openrouter")[:input],
                   "the vendor's own listing answers for a gateway's copy the registry lacks"
      assert_equal 3.0, Pricing.rate_detail("claude-sonnet-4-5-20250929", provider: "anthropic")[:input], "a dated id is tried undated"
    end
  end

  test "without the registry the static rows price the current models ahead of the family patterns" do
    without_ruby_llm do
      assert_equal({ input: 2.0, output: 10.0, source: "pattern" }, Pricing.rate_detail("claude-sonnet-5"))
      assert_equal({ input: 2.0, output: 10.0, source: "pattern" }, Pricing.rate_detail("anthropic/claude-sonnet-5", provider: "openrouter"))
      assert_equal 2.0, Pricing.rate_detail("claude-sonnet-5-20260601")[:input]
      assert_equal 3.0, Pricing.rate_detail("claude-sonnet-4-5")[:input], "an older Sonnet keeps the family rate"
      assert_equal({ input: 5.0, output: 30.0, source: "pattern" }, Pricing.rate_detail("gpt-5.5"))
      assert_equal({ input: 5.0, output: 30.0, source: "pattern" }, Pricing.rate_detail("openai/gpt-5.5", provider: "openrouter"))
      assert_equal 0.25, Pricing.rate_detail("gpt-5-mini")[:input]
      assert_equal({ input: 0.15, output: 0.6, source: "pattern" }, Pricing.rate_detail("gpt-4o-mini"))
      assert_equal({ input: 1.0, output: 4.0, source: "default" }, Pricing.rate_detail("some-new-model"))
      assert_equal [ 1.0, 4.0 ], Pricing.rate_for(nil)
    end
  end

  test "estimate_detailed shows the working and nothing is priced from no tokens" do
    without_ruby_llm do
      detail = Pricing.estimate_detailed(model: "gpt-4o-mini", input_tokens: 1_000, output_tokens: 100)
      assert_in_delta 0.00021, detail[:cost], 1e-12
      assert_equal [ 0.15, 0.6, "pattern" ], detail.values_at(:input_rate, :output_rate, :source)
      assert_nil Pricing.estimate_detailed(model: "gpt-4o-mini", input_tokens: 0, output_tokens: 0)
      assert_nil Pricing.estimate(model: "gpt-4o-mini", input_tokens: nil, output_tokens: nil)
    end
  end

  test "rates are memoized per provider and model" do
    with_registry do
      3.times { Pricing.rate_detail("gpt-5.5", provider: "openrouter") }
      assert_equal 1, Registry.lookups.size
      Pricing.rate_detail("gpt-5.5")
      assert_equal 2, Registry.lookups.size, "the same model under another provider is another entry"
    end
  end

  test "the fingerprint names the tables in force and changes with the registry" do
    with_registry do
      fingerprint = Pricing.fingerprint
      assert_match(/\A[0-9a-f]{12}\z/, fingerprint)
      assert_equal fingerprint, Pricing.fingerprint
      without_ruby_llm { assert_not_equal fingerprint, Pricing.fingerprint }
    end
  end

  test "normalize keys one row for every spelling of a model" do
    assert_equal "claude-sonnet-4-5", Pricing.normalize("openrouter/anthropic/claude-sonnet-4.5-20250929")
    assert_equal "gpt-4o-mini", Pricing.normalize("gpt-4o-mini-2024-07-18")
    assert_equal "gpt-oss:120b", Pricing.normalize("gpt-oss:120b-cloud")
    assert_equal "glm-4-6", Pricing.normalize("glm-4.6:cloud")
  end

  test "an Ollama model is priced from the cloud's listing by the name the cloud uses, whichever route served it" do
    with_registry do
      assert_equal({ input: 0.15, output: 0.6, source: "catalog" }, Pricing.rate_detail("gpt-oss:120b", provider: "Ollama"))
      assert_equal [ "gpt-oss:120b", "ollama_cloud" ], Registry.lookups.first, "a trace's Ollama tag reads as the cloud's listing"
      assert_equal 0.15, Pricing.rate_detail("gpt-oss:120b-cloud")[:input], "a local server's spelling names the cloud's model"
      assert_equal 0.22, Pricing.rate_detail("deepseek-v4-flash", provider: "ollama")[:input], "Ollama's price for the model, not the vendor's"
      assert_equal 0.15, Pricing.rate_detail("deepseek-v4-flash")[:input], "the vendor's own listing answers without a provider"
    end
  end

  test "a provider is read as the registry names it, from a trace's tag or a run's key" do
    assert_equal "openai", Pricing.provider_slug("OpenAI::Chat")
    assert_equal "openai", Pricing.provider_slug("OpenAI::Responses")
    assert_equal "openrouter", Pricing.provider_slug("open_router")
    assert_equal "ollama", Pricing.provider_slug("Ollama")
    assert_equal "ollama_cloud", Pricing.provider_slug("ollama-cloud")
    assert_nil Pricing.provider_slug(nil)
    assert_nil Pricing.provider_slug(" ")

    with_registry do
      Pricing.rate_detail("gpt-5.5", provider: "OpenAI::Chat")
      assert_equal [ "gpt-5.5", "openai" ], Registry.lookups.first
    end
  end

  test "without the registry Ollama Cloud's bundled price list prices an Ollama model, and nothing else" do
    without_ruby_llm do
      assert_equal({ input: 0.15, output: 0.6, source: "catalog" }, Pricing.rate_detail("gpt-oss:120b", provider: "ollama"))
      assert_equal({ input: 0.15, output: 0.6, source: "catalog" }, Pricing.rate_detail("gpt-oss:120b-cloud"))
      assert_equal({ input: 1.4, output: 4.4, source: "catalog" }, Pricing.rate_detail("glm-5.3:latest", provider: "Ollama"))
      assert_equal({ input: 0.22, output: 0.66, source: "catalog" }, Pricing.rate_detail("deepseek-v4-flash", provider: "ollama_cloud"))
      assert_equal({ input: 0.2, output: 0.6, source: "pattern" }, Pricing.rate_detail("qwen3:8b", provider: "ollama"),
                   "a model the cloud does not list keeps its family rate")
      assert_equal "default", Pricing.rate_detail("gpt-oss:120b")[:source], "a bare name under no provider is not taken for Ollama's"
      assert_in_delta 0.75, Pricing.estimate(model: "gpt-oss:120b", provider: "Ollama", input_tokens: 1_000_000, output_tokens: 1_000_000), 1e-9
    end
  end
end
