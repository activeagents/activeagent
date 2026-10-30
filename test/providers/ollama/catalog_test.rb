# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Ollama catalog tests"
  return
end

require_relative "../../../lib/active_agent/providers/ollama_provider"

module Providers
  module Ollama
    # The models a host serves, read from its own API: a local server's
    # listing with the cloud models it relays, Ollama Cloud's listing with
    # the key, one model described, and the failures named.
    class CatalogTest < ActiveSupport::TestCase
      include WebMock::API

      Catalog = ActiveAgent::Providers::Ollama::Catalog

      test "lists the models a local server serves, marking the ones it relays to the cloud" do
        stub_request(:get, "http://mini.local:11434/api/tags").to_return(json(
          models: [
            { name: "qwen3:8b", model: "qwen3:8b", size: 5_225_000_000, modified_at: "2026-10-01T10:00:00Z",
              details: { family: "qwen3", parameter_size: "8.2B", quantization_level: "Q4_K_M" } },
            { name: "gpt-oss:120b-cloud", model: "gpt-oss:120b-cloud", size: 0,
              details: { family: "gptoss", parameter_size: "116.8B" },
              remote_model: "gpt-oss:120b", remote_host: "https://ollama.com:443" }
          ]
        ))

        catalog = Catalog.new(host: "http://mini.local:11434")
        models = catalog.models

        assert_not catalog.cloud?
        assert_equal %w[qwen3:8b gpt-oss:120b-cloud], models.map(&:name)
        local, relayed = models
        assert_not local.cloud?
        assert_equal [ "qwen3", "8.2B", "Q4_K_M", 5_225_000_000 ], [ local.family, local.parameter_size, local.quantization_level, local.size ]
        assert_equal "qwen3:8b", local.canonical_name
        assert relayed.cloud?
        assert_equal "gpt-oss:120b", relayed.canonical_name
        assert_equal({ name: "gpt-oss:120b-cloud", canonical_name: "gpt-oss:120b", cloud: true,
                       details: { "family" => "gptoss", "parameter_size" => "116.8B" },
                       capabilities: [], context_length: nil, size: 0, modified_at: nil }, relayed.to_h)
        assert_requested(:get, "http://mini.local:11434/api/tags") { |request| !request.headers.key?("Authorization") }
      end

      test "lists Ollama Cloud's models with the key, every one a cloud model" do
        stub_request(:get, "https://ollama.com/api/tags")
          .with(headers: { "Authorization" => "Bearer sk-cloud" })
          .to_return(json(models: [
            { name: "gpt-oss:120b", details: { family: "gptoss", parameter_size: "116.8B" } },
            { name: "kimi-k3", details: { family: "deepseek2" } }
          ]))

        catalog = Catalog.new(host: "https://ollama.com", api_key: "sk-cloud")

        assert catalog.cloud?
        assert_equal "https://ollama.com/v1", catalog.host
        assert_equal %w[gpt-oss:120b kimi-k3], catalog.model_names
        assert catalog.models.all?(&:cloud?)
      end

      test "describes a model: its details, capabilities and context length" do
        stub_request(:post, "http://mini.local:11434/api/show")
          .with(body: { model: "qwen3:8b" }.to_json, headers: { "Content-Type" => "application/json" })
          .to_return(json(
            details: { family: "qwen3", parameter_size: "8.2B", quantization_level: "Q4_K_M" },
            capabilities: %w[completion tools thinking],
            model_info: { "general.architecture" => "qwen3", "qwen3.context_length" => 40_960, "qwen3.embedding_length" => 4096 },
            modified_at: "2026-10-01T10:00:00Z"
          ))

        model = Catalog.new(host: "http://mini.local:11434").model_info("qwen3:8b")

        assert_equal "qwen3:8b", model.name
        assert_not model.cloud?
        assert_equal %w[completion tools thinking], model.capabilities
        assert_equal 40_960, model.context_length
        assert_equal "qwen3", model.family
        assert_equal "2026-10-01T10:00:00Z", model.modified_at
      end

      test "a server with only the OpenAI-compatible API is listed through /v1/models" do
        stub_request(:get, "https://proxy.example.com/ollama/api/tags").to_return(status: 404, body: "not found")
        stub_request(:get, "https://proxy.example.com/ollama/v1/models")
          .with(headers: { "Authorization" => "Bearer sk-proxy" })
          .to_return(json(object: "list", data: [ { id: "gpt-oss:120b", object: "model" }, { id: "glm-4.6:cloud", object: "model" } ]))

        models = Catalog.new(host: "https://proxy.example.com/ollama", api_key: "sk-proxy").models

        assert_equal %w[gpt-oss:120b glm-4.6:cloud], models.map(&:name)
        assert_equal [ false, true ], models.map(&:cloud?), "only the marker says a proxied model is the cloud's"
        assert_equal [ {}, {} ], models.map(&:details)
      end

      test "the failures are named" do
        stub_request(:get, "https://ollama.com/api/tags").to_return(status: 401, body: "")
        error = assert_raises(Catalog::AuthenticationError) { Catalog.new(host: "https://ollama.com", api_key: "sk-bad").models }
        assert_match(/401/, error.message)

        stub_request(:get, "http://down.local:11434/api/tags").to_raise(Errno::ECONNREFUSED)
        error = assert_raises(Catalog::ConnectionError) { Catalog.new(host: "http://down.local:11434").models }
        assert_match(/Could not reach http:\/\/down.local:11434\/v1/, error.message)

        stub_request(:get, "http://slow.local:11434/api/tags").to_timeout
        assert_raises(Catalog::ConnectionError) { Catalog.new(host: "http://slow.local:11434").models }

        stub_request(:post, "http://mini.local:11434/api/show").to_return(status: 404, body: { error: "model 'nope' not found" }.to_json)
        error = assert_raises(Catalog::NotFoundError) { Catalog.new(host: "http://mini.local:11434").model_info("nope") }
        assert_match(/does not serve nope/, error.message)

        stub_request(:get, "http://mini.local:11434/api/tags").to_return(status: 200, body: "Ollama is running")
        error = assert_raises(Catalog::Error) { Catalog.new(host: "http://mini.local:11434").models }
        assert_match(/did not return JSON/, error.message)

        stub_request(:get, "http://mini.local:11434/api/tags").to_return(status: 500, body: "")
        assert_raises(Catalog::Error) { Catalog.new(host: "http://mini.local:11434").models }
      end

      test "the provider reads its own host with its key, never the local placeholder" do
        stub_request(:get, "http://mini.local:11434/api/tags").to_return(json(models: [ { name: "qwen3:8b" } ]))
        stub_request(:post, "http://mini.local:11434/api/show").to_return(json(capabilities: %w[completion]))

        provider = ActiveAgent::Providers::OllamaProvider.new(
          service: "Ollama", model: "qwen3:8b", host: "http://mini.local:11434", api_key: "ollama"
        )

        assert_equal %w[qwen3:8b], provider.models.map(&:name)
        assert_equal %w[completion], provider.model_info("qwen3:8b").capabilities
        assert_requested(:get, "http://mini.local:11434/api/tags") { |request| !request.headers.key?("Authorization") }

        stub_request(:get, "https://ollama.com/api/tags")
          .with(headers: { "Authorization" => "Bearer sk-cloud" })
          .to_return(json(models: [ { name: "gpt-oss:120b" } ]))
        cloud = ActiveAgent::Providers::OllamaProvider.new(service: "Ollama", model: "gpt-oss:120b", cloud: true, api_key: "sk-cloud")

        assert cloud.catalog.cloud?
        assert_equal %w[gpt-oss:120b], cloud.models.map(&:name)
      end

      private

      def json(body)
        { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
      end
    end
  end
end
