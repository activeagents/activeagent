# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Ollama Cloud tests"
  return
end

require_relative "../../../lib/active_agent/providers/ollama_provider"

module Providers
  module Ollama
    # Ollama Cloud: the host and model-name rules, and a cloud agent's
    # request reaching ollama.com with its key.
    class CloudTest < ActiveSupport::TestCase
      include WebMock::API

      ENV_NAMES = %w[OLLAMA_HOST OLLAMA_API_KEY OLLAMA_ACCESS_TOKEN].freeze
      ENDPOINT = "https://ollama.com/v1/chat/completions"
      Cloud = ActiveAgent::Providers::Ollama::Cloud

      test "tells the cloud host from a local one" do
        assert Cloud.cloud_host?("https://ollama.com")
        assert Cloud.cloud_host?("https://ollama.com/v1")
        assert Cloud.cloud_host?("https://api.ollama.com/v1")
        assert_not Cloud.cloud_host?("http://127.0.0.1:11434/v1")
        assert_not Cloud.cloud_host?("https://ollama.com.example.com/v1")
        assert_not Cloud.cloud_host?(nil)
        assert_not Cloud.cloud_host?("not a url")
      end

      test "reduces a local server's spelling of a cloud model to the cloud's name" do
        assert Cloud.cloud_model?("gpt-oss:120b-cloud")
        assert Cloud.cloud_model?("glm-4.6:cloud")
        assert_not Cloud.cloud_model?("gpt-oss:120b")
        assert_not Cloud.cloud_model?("qwen3:8b")

        assert_equal "gpt-oss:120b", Cloud.canonical_model("gpt-oss:120b-cloud")
        assert_equal "glm-4.6", Cloud.canonical_model("glm-4.6:cloud")
        assert_equal "kimi-k2:1t", Cloud.canonical_model("kimi-k2:1t-cloud")
        assert_equal "gpt-oss:120b", Cloud.canonical_model("gpt-oss:120b")
        assert_equal "qwen3:8b", Cloud.canonical_model(" qwen3:8b ")
      end

      test "completes a server address to the base URL of its OpenAI-compatible API" do
        assert_equal "http://localhost:11434/v1", Cloud.normalize_host("http://localhost:11434")
        assert_equal "http://localhost:11434/v1", Cloud.normalize_host("http://localhost:11434/")
        assert_equal "http://localhost:11434/v1", Cloud.normalize_host(" http://localhost:11434/v1/ ")
        assert_equal "http://localhost:11434/v1", Cloud.normalize_host("http://localhost")
        assert_equal "http://0.0.0.0:11434/v1", Cloud.normalize_host("0.0.0.0")
        assert_equal "http://mini.local:8080/v1", Cloud.normalize_host("mini.local:8080")
        assert_equal "https://ollama.com/v1", Cloud.normalize_host("https://ollama.com")
        assert_equal "https://ollama.com/v1", Cloud.normalize_host("ollama.com")
        assert_equal "https://ai.example.com/ollama/v1", Cloud.normalize_host("https://ai.example.com/ollama/v1")
        assert_nil Cloud.normalize_host("")
        assert_nil Cloud.normalize_host(nil)

        assert_equal "https://ollama.com", Cloud.api_origin("https://ollama.com/v1")
        assert_equal "http://127.0.0.1:11434", Cloud.api_origin("http://127.0.0.1:11434/v1/")
        assert_equal "https://ai.example.com/ollama", Cloud.api_origin("https://ai.example.com/ollama/v1")
      end

      test "a cloud agent's request reaches ollama.com with its key" do
        stub_request(:post, ENDPOINT).to_return(
          status: 200, headers: { "Content-Type" => "application/json" }, body: chat_completion.to_json
        )

        with_env("OLLAMA_API_KEY" => "sk-cloud") do
          provider = ActiveAgent::Providers::OllamaProvider.new(
            service: "Ollama", cloud: true, model: "gpt-oss:120b",
            messages: [ { role: "user", content: "hi" } ]
          )

          assert provider.cloud?
          response = provider.prompt

          assert_equal "Hello from the cloud.", response.message.content
        end

        assert_requested(:post, ENDPOINT, headers: { "Authorization" => "Bearer sk-cloud" }) do |request|
          JSON.parse(request.body)["model"] == "gpt-oss:120b"
        end
      end

      test "a cloud request without a key fails before it is sent" do
        with_env do
          provider = ActiveAgent::Providers::OllamaProvider.new(
            service: "Ollama", cloud: true, model: "gpt-oss:120b",
            messages: [ { role: "user", content: "hi" } ]
          )

          error = assert_raises(ActiveAgent::Providers::Errors::AuthenticationFailed) { provider.prompt }
          assert_match(/OLLAMA_API_KEY/, error.message)
        end

        assert_not_requested(:post, ENDPOINT)
      end

      private

      def chat_completion
        {
          id: "chatcmpl-ollama-cloud",
          object: "chat.completion",
          created: 1_700_000_000,
          model: "gpt-oss:120b",
          choices: [ { index: 0, message: { role: "assistant", content: "Hello from the cloud." }, finish_reason: "stop" } ],
          usage: { prompt_tokens: 3, completion_tokens: 5, total_tokens: 8 }
        }
      end

      def with_env(values = {})
        names = ENV_NAMES | values.keys
        previous = names.to_h { |name| [ name, ENV[name] ] }
        names.each { |name| ENV.delete(name) }
        values.each { |name, value| ENV[name] = value }
        yield
      ensure
        previous.each { |name, value| ENV[name] = value }
      end
    end
  end
end
