# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping UberLLM request tests"
  return
end

require_relative "../../../lib/active_agent/providers/uber_llm_provider"

module Providers
  module UberLLM
    class RequestTest < ActiveSupport::TestCase
      include WebMock::API

      CHAT_ENDPOINT = "https://api.uberllm.dev/v1/chat/completions"

      # Cleared around every test so a key in the developer's or the CI
      # environment cannot decide the outcome.
      KEY_ENV = %w[
        UBERLLM_API_KEY
        OPENAI_API_KEY
      ].freeze

      # =====================================================================
      # Options
      # =====================================================================

      test "falls back to UBERLLM_API_KEY when no explicit key is given" do
        with_key_env("UBERLLM_API_KEY" => "ull-env") do
          assert_equal "ull-env", ActiveAgent::Providers::UberLLM::Options.new.api_key
        end
      end

      test "prefers an explicit api_key over UBERLLM_API_KEY" do
        with_key_env("UBERLLM_API_KEY" => "ull-env") do
          options = ActiveAgent::Providers::UberLLM::Options.new(api_key: "ull-explicit")

          assert_equal "ull-explicit", options.api_key
        end
      end

      test "does not fall back to OPENAI_API_KEY" do
        with_key_env("OPENAI_API_KEY" => "sk-openai-env") do
          assert_nil ActiveAgent::Providers::UberLLM::Options.new.api_key
        end
      end

      # =====================================================================
      # Prompt
      # =====================================================================

      test "sends a prompt to the UberLLM chat completions endpoint with the explicit key" do
        stub_chat_completion

        with_key_env("UBERLLM_API_KEY" => "ull-env", "OPENAI_API_KEY" => "sk-openai-env") do
          prompt_provider(api_key: "ull-explicit").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer ull-explicit" })
      end

      test "sends a prompt with the UBERLLM_API_KEY key when no explicit key is given" do
        stub_chat_completion

        with_key_env("UBERLLM_API_KEY" => "ull-env") do
          prompt_provider.prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer ull-env" })
      end

      test "sends vendor-prefixed model ids unchanged" do
        stub_chat_completion

        with_key_env("UBERLLM_API_KEY" => "ull-env") do
          prompt_provider(model: "deepseek/deepseek-v4.1-flash").prompt
          prompt_provider(model: "z-ai/glm-5.2").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "deepseek/deepseek-v4.1-flash" }
        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "z-ai/glm-5.2" }
      end

      test "returns the assistant message from the response" do
        stub_chat_completion

        response = with_key_env("UBERLLM_API_KEY" => "ull-env") do
          prompt_provider.prompt
        end

        assert_equal "Hello.", response.message.content
      end

      # =====================================================================
      # Embeddings
      # =====================================================================

      test "does not support embeddings" do
        assert_raises(NotImplementedError) do
          ActiveAgent::Providers::UberLLMProvider.embed_request_type
        end
      end

      private

      def prompt_provider(model: "deepseek/deepseek-v4.1-flash", **credential)
        ActiveAgent::Providers::UberLLMProvider.new(
          service: "UberLLM",
          model: model,
          messages: [ { role: "user", content: "hi" } ],
          **credential
        )
      end

      def stub_chat_completion
        stub_request(:post, CHAT_ENDPOINT).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: chat_completion.to_json
        )
      end

      def chat_completion
        {
          id: "chatcmpl-uberllm-request",
          object: "chat.completion",
          created: 1_700_000_000,
          model: "deepseek/deepseek-v4.1-flash",
          choices: [ { index: 0, message: { role: "assistant", content: "Hello." }, finish_reason: "stop" } ],
          usage: { prompt_tokens: 3, completion_tokens: 2, total_tokens: 5 }
        }
      end

      # Clears every variable in KEY_ENV, applies values on top, and restores
      # the original environment afterwards.
      def with_key_env(values = {})
        names = KEY_ENV | values.keys
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
