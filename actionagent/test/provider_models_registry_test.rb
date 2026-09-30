# frozen_string_literal: true

require "test_helper"
require_relative "support/ruby_llm_constant"

# Loading the gem over the provider tests' stand-in for it breaks both, so it
# is loaded only when neither is there yet.
unless defined?(::RubyLLM::Models)
  begin
    require "ruby_llm"
  rescue LoadError
    # The tests that need the gem skip without it.
  end
end

# GET /api/provider_models adds the chat models the host's RubyLLM registry
# lists that take and return text after the live or curated ones. The tests
# build registries of real RubyLLM model entries rather than reading the one
# the gem bundles, which changes with every release, and skip when the
# provider tests' stand-in for the gem loaded first. One builds its registry
# from plain objects instead, so the filter is tested in any load order.
class ProviderModelsRegistryTest < ActionDispatch::IntegrationTest
  include RubyLLMConstant

  CURATED = ActionAgent::Api::ProviderModelsController::CURATED

  def setup
    ActionAgent::ProviderKey.delete_all
  end

  test "the registry's chat models for the provider follow the curated list, each once" do
    registry = ruby_llm_registry(
      [ "gpt-5", "openai", %w[text] ],
      [ "gpt-4.1", "openai", %w[text] ],
      [ "claude-haiku-4-5", "anthropic", %w[text] ]
    )

    with_registry(registry) { get "/activeagents/api/provider_models", params: { provider: "openai" } }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "curated", body["source"]
    assert_equal CURATED["openai"] + %w[gpt-4.1], body["models"]
  end

  # RubyLLM counts a model with no output modalities as a chat model, and its
  # registry lists speech, transcription and completion-only models that way,
  # or lists transcription models as taking audio.
  test "only the registry's models that take and return text are listed" do
    registry = ruby_llm_registry(
      [ "gpt-4.1", "openai", %w[text] ],
      [ "gpt-4o", "openai", %w[text], %w[text image] ],
      [ "whisper-1", "openai", [] ],
      [ "gpt-4o-transcribe", "openai", %w[text], %w[audio] ],
      [ "tts-1", "openai", [] ],
      [ "babbage-002", "openai", [] ],
      [ "text-embedding-3-small", "openai", %w[embeddings] ],
      [ "gpt-image-2", "openai", %w[text image] ],
      [ "gpt-audio", "openai", %w[text audio] ]
    )

    with_registry(registry) { get "/activeagents/api/provider_models", params: { provider: "openai" } }

    assert_response :success
    assert_equal CURATED["openai"] + %w[gpt-4.1 gpt-4o], JSON.parse(response.body)["models"]
  end

  test "a live list keeps its lead, and the registry's models follow it" do
    ActionAgent::ProviderKey.create!(provider: "anthropic", credential: "sk-ant-registry")
    stub_request(:get, "https://api.anthropic.com/v1/models?limit=50")
      .with(headers: { "x-api-key" => "sk-ant-registry" })
      .to_return(status: 200, body: { data: [ { id: "claude-sonnet-5" }, { id: "claude-opus-5" } ] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    registry = ruby_llm_registry([ "claude-haiku-4-5", "anthropic", %w[text] ], [ "claude-opus-5", "anthropic", %w[text] ])

    with_registry(registry) { get "/activeagents/api/provider_models", params: { provider: "anthropic" } }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "live", body["source"]
    assert_equal %w[claude-sonnet-5 claude-opus-5 claude-haiku-4-5], body["models"]
  end

  test "without RubyLLM the list is the curated one alone" do
    without_ruby_llm do
      get "/activeagents/api/provider_models", params: { provider: "openai" }
    end

    assert_response :success
    assert_equal CURATED["openai"], JSON.parse(response.body)["models"]
  end

  test "a registry of plain objects lists its chat models that take and return text" do
    modalities = Struct.new(:input, :output)
    entry = Struct.new(:id, :modalities)
    chat_models = [
      entry.new("gpt-5", modalities.new(%w[text], %w[text])),
      entry.new("gpt-4.1", modalities.new(%w[text image], %w[text])),
      entry.new("gpt-4o-transcribe", modalities.new(%w[audio], %w[text])),
      entry.new("tts-1", modalities.new([], [])),
      entry.new("", modalities.new(%w[text], %w[text]))
    ]
    registry = Object.new
    registry.define_singleton_method(:by_provider) do |provider|
      Struct.new(:chat_models).new(provider == "openai" ? chat_models : [])
    end
    ruby_llm = Module.new
    ruby_llm.define_singleton_method(:models) { registry }

    with_ruby_llm_constant(ruby_llm) do
      get "/activeagents/api/provider_models", params: { provider: "openai" }
    end

    assert_response :success
    assert_equal CURATED["openai"] + %w[gpt-4.1], JSON.parse(response.body)["models"]
  end

  test "a registry that raises leaves the curated list" do
    ruby_llm = Module.new
    ruby_llm.define_singleton_method(:models) { raise "no such table: models" }

    with_ruby_llm_constant(ruby_llm) do
      get "/activeagents/api/provider_models", params: { provider: "openai" }
    end

    assert_response :success
    assert_equal CURATED["openai"], JSON.parse(response.body)["models"]
  end

  private

  # Returns a RubyLLM registry of the given `[id, provider, output
  # modalities, input modalities]` entries. Input is text unless given.
  def ruby_llm_registry(*entries)
    # The provider tests' stand-in defines RubyLLM::Models as a module.
    skip "the ruby_llm gem is not loaded" unless defined?(::RubyLLM::Models) && ::RubyLLM::Models.is_a?(Class)

    # RubyLLM 1.x names a registry entry Model::Info, and 2.x Model.
    model_class = defined?(::RubyLLM::Model::Info) ? ::RubyLLM::Model::Info : ::RubyLLM::Model
    ::RubyLLM::Models.new(entries.map do |id, provider, output, input = %w[text]|
      model_class.new(id: id, name: id, provider: provider, modalities: { input: input, output: output })
    end)
  end

  def with_registry(registry, &)
    ::RubyLLM.stub(:models, registry, &)
  end
end
