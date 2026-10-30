# frozen_string_literal: true

require "test_helper"
require_relative "support/ruby_llm_constant"

# Settings -> Provider API Keys for a host-based provider (Ollama): the host
# is normalized, an optional API key is stored beside it for remote servers,
# and "Test connection" probes a submitted or stored host without saving.
# A probe says whether the host is Ollama Cloud and prices the models a
# price list names.
class ProviderHostSettingsTest < ActionDispatch::IntegrationTest
  include RubyLLMConstant

  def setup
    ActionAgent::ProviderKey.delete_all
  end

  def models_response(*ids)
    { status: 200, body: { data: ids.map { |id| { id: id } } }.to_json,
      headers: { "Content-Type" => "application/json" } }
  end

  test "a bare host is normalized to the /v1 endpoint" do
    assert_equal "http://localhost:11434/v1", ActionAgent::ProviderKey.normalize_host("http://localhost:11434")
    assert_equal "http://localhost:11434/v1", ActionAgent::ProviderKey.normalize_host("http://localhost:11434/")
    assert_equal "http://localhost:11434/v1", ActionAgent::ProviderKey.normalize_host(" http://localhost:11434/v1/ ")
    assert_equal "https://ollama.com/v1", ActionAgent::ProviderKey.normalize_host("https://ollama.com")
    # An explicit non-root path is left alone (reverse proxies).
    assert_equal "https://ai.example.com/ollama/v1", ActionAgent::ProviderKey.normalize_host("https://ai.example.com/ollama/v1")

    key = ActionAgent::ProviderKey.create!(provider: "ollama", credential: "http://mac-mini.local:11434")
    assert_equal "http://mac-mini.local:11434/v1", key.credential
    assert_equal({ host: "http://mac-mini.local:11434/v1" }, key.generation_options)
  end

  test "an ollama key carries an optional api key, encrypted, sent as the access token" do
    key = ActionAgent::ProviderKey.create!(provider: "ollama", credential: "https://ollama.com", api_key: " sk-remote-abcd1234 ")

    assert key.api_key?
    assert_equal "sk-remote-abcd1234", key.reload.api_key
    assert_equal({ host: "https://ollama.com/v1", access_token: "sk-remote-abcd1234" }, key.generation_options)
    assert_equal "sk-r…1234", key.api_key_hint

    connection = ActionAgent::ProviderKey.connection
    stored = connection.select_value(
      "SELECT api_key FROM #{connection.quote_table_name(ActionAgent::ProviderKey.table_name)} " \
      "WHERE id = #{connection.quote(key.id)}"
    )
    assert_not_equal "sk-remote-abcd1234", stored, "the stored column must not hold the plain key"

    key.update!(api_key: "")
    assert_not key.api_key?
    assert_nil key.api_key_hint
    assert_equal({ host: "https://ollama.com/v1" }, key.generation_options)

    api = ActionAgent::ProviderKey.create!(provider: "openai", credential: "sk-test", api_key: "unused")
    assert_not api.api_key?
    assert_equal({ access_token: "sk-test" }, api.generation_options)
  end

  test "the settings API stores a masked api key, keeps it when omitted and clears it when blank" do
    post "/activeagents/api/provider_keys",
      params: { provider: "ollama", credential: "https://ollama.com", api_key: "sk-remote-abcd1234" }, as: :json

    assert_response :created
    row = JSON.parse(response.body)["provider_key"]
    assert_equal "https://ollama.com/v1", row["hint"]
    assert row["api_key_configured"]
    assert_equal "sk-r…1234", row["api_key_hint"]
    assert_not_includes response.body, "sk-remote-abcd1234"

    post "/activeagents/api/provider_keys", params: { provider: "ollama", credential: "https://ollama.com/v1" }, as: :json
    assert_equal "sk-remote-abcd1234", ActionAgent::ProviderKey.find_by!(provider: "ollama").api_key

    post "/activeagents/api/provider_keys", params: { provider: "ollama", credential: "https://ollama.com/v1", api_key: "" }, as: :json
    assert_nil ActionAgent::ProviderKey.find_by!(provider: "ollama").api_key
    assert_not JSON.parse(response.body).dig("provider_key", "api_key_configured")

    get "/activeagents/api/provider_keys"
    ollama = JSON.parse(response.body)["provider_keys"].find { |r| r["provider"] == "ollama" }
    assert ollama["configured"]
    assert_not ollama["api_key_configured"]
    assert_nil ollama["platform_default"]
  end

  test "test probes a submitted host and key without saving them" do
    stub_request(:get, "http://mini.local:11434/v1/models")
      .with(headers: { "Authorization" => "Bearer sk-x" })
      .to_return(models_response("qwen3:4b", "llama3.2:3b"))

    post "/activeagents/api/provider_keys/test",
      params: { provider: "ollama", credential: "http://mini.local:11434", api_key: "sk-x" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"], body.inspect
    assert_equal "http://mini.local:11434/v1", body["host"]
    assert_equal %w[llama3.2:3b qwen3:4b], body["models"]
    assert_kind_of Integer, body["latency_ms"]
    assert_nil ActionAgent::ProviderKey.find_by(provider: "ollama")
  end

  test "test falls back to the stored host and key, and reports failures without raising" do
    ActionAgent::ProviderKey.create!(provider: "ollama", credential: "http://stored:11434", api_key: "sk-stored")
    stub_request(:get, "http://stored:11434/v1/models")
      .with(headers: { "Authorization" => "Bearer sk-stored" })
      .to_return(status: 401, body: "")

    post "/activeagents/api/provider_keys/test", params: { provider: "ollama" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["ok"]
    assert_match(/401/, body["error"])
    assert_match(/API key/, body["error"])
    assert_empty body["models"]

    stub_request(:get, "http://stored:11434/v1/models").to_raise(Errno::ECONNREFUSED)
    post "/activeagents/api/provider_keys/test", params: { provider: "ollama" }, as: :json
    assert_match(/Could not connect/, JSON.parse(response.body)["error"])

    stub_request(:get, "http://stored:11434/v1/models").to_return(status: 200, body: "Ollama is running")
    post "/activeagents/api/provider_keys/test", params: { provider: "ollama" }, as: :json
    assert_match(%r{/v1}, JSON.parse(response.body)["error"])
  end

  test "test reports no host when nothing is configured and rejects key-based providers" do
    post "/activeagents/api/provider_keys/test", params: { provider: "ollama" }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["ok"]
    assert_equal "No host configured", body["error"]

    post "/activeagents/api/provider_keys/test", params: { provider: "openai" }, as: :json
    assert_response :unprocessable_entity
  end

  test "the builder's live Ollama model list uses the stored host and key" do
    ActionAgent::ProviderKey.create!(provider: "ollama", credential: "http://mini.local:11434", api_key: "sk-x")
    stub_request(:get, "http://mini.local:11434/v1/models")
      .with(headers: { "Authorization" => "Bearer sk-x" })
      .to_return(models_response("qwen3:4b"))

    get "/activeagents/api/provider_models", params: { provider: "ollama" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "live", body["source"], body.inspect
    assert_equal %w[qwen3:4b], body["models"]
    assert_equal false, body["cloud"]
    assert_equal({}, body["rates"], "a model only a pattern prices has no rate")
  end

  test "the probe says whether the host is Ollama Cloud and prices the models a list names" do
    stub_request(:get, "https://ollama.com/v1/models")
      .with(headers: { "Authorization" => "Bearer sk-cloud" })
      .to_return(models_response("kimi-k3", "gpt-oss:120b", "preview-model:latest"))

    without_ruby_llm do
      post "/activeagents/api/provider_keys/test",
        params: { provider: "ollama", credential: "https://ollama.com", api_key: "sk-cloud" }, as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"], body.inspect
    assert_equal true, body["cloud"]
    assert_equal %w[gpt-oss:120b kimi-k3 preview-model:latest], body["models"]
    assert_equal({ "gpt-oss:120b" => { "input" => 0.15, "output" => 0.6, "source" => "catalog" },
                   "kimi-k3" => { "input" => 3.0, "output" => 15.0, "source" => "catalog" } }, body["rates"])

    assert ActionAgent::OllamaHostProbe.cloud_host?("https://ollama.com/v1")
    assert_not ActionAgent::OllamaHostProbe.cloud_host?("http://mini.local:11434/v1")
  end

  test "a local server is not the cloud, and its copy of a cloud model is priced at the cloud's rate" do
    stub_request(:get, "http://mini.local:11434/v1/models").to_return(models_response("qwen3:4b", "gpt-oss:20b"))

    without_ruby_llm do
      post "/activeagents/api/provider_keys/test", params: { provider: "ollama", credential: "http://mini.local:11434" }, as: :json
    end

    body = JSON.parse(response.body)
    assert_equal false, body["cloud"]
    assert_equal({ "gpt-oss:20b" => { "input" => 0.07, "output" => 0.3, "source" => "catalog" } }, body["rates"])

    post "/activeagents/api/provider_keys/test", params: { provider: "ollama" }, as: :json
    body = JSON.parse(response.body)
    assert_equal [ false, nil, {} ], body.values_at("ok", "cloud", "rates"), "an unanswered probe has the same shape"
  end

  test "the builder's Ollama list says whether the host is the cloud and carries the rates" do
    ActionAgent::ProviderKey.create!(provider: "ollama", credential: "https://ollama.com", api_key: "sk-cloud")
    stub_request(:get, "https://ollama.com/v1/models")
      .with(headers: { "Authorization" => "Bearer sk-cloud" })
      .to_return(models_response("gpt-oss:120b"))

    without_ruby_llm { get "/activeagents/api/provider_models", params: { provider: "ollama" } }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "live", body["source"]
    assert_equal true, body["cloud"]
    assert_equal({ "gpt-oss:120b" => { "input" => 0.15, "output" => 0.6, "source" => "catalog" } }, body["rates"])

    without_ruby_llm { get "/activeagents/api/provider_models", params: { provider: "openai" } }
    assert_not JSON.parse(response.body).key?("cloud")
  end
end
