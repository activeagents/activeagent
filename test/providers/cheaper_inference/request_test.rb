# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Cheaper Inference request tests"
  return
end

require_relative "../../../lib/active_agent/providers/cheaper_inference_provider"

module Providers
  module CheaperInference
    class RequestTest < ActiveSupport::TestCase
      include WebMock::API

      CHAT_ENDPOINT = "https://api.cheaperinference.com/v1/chat/completions"
      EMBEDDINGS_ENDPOINT = "https://api.cheaperinference.com/v1/embeddings"

      # Cleared around every test so a key in the developer's or the CI
      # environment cannot decide the outcome.
      KEY_ENV = %w[
        CHEAPER_INFERENCE_API_KEY
        OPENAI_API_KEY
      ].freeze

      # =====================================================================
      # Options
      # =====================================================================

      test "falls back to CHEAPER_INFERENCE_API_KEY when no explicit key is given" do
        with_key_env("CHEAPER_INFERENCE_API_KEY" => "ci-env") do
          assert_equal "ci-env", ActiveAgent::Providers::CheaperInference::Options.new.api_key
        end
      end

      test "prefers an explicit api_key over CHEAPER_INFERENCE_API_KEY" do
        with_key_env("CHEAPER_INFERENCE_API_KEY" => "ci-env") do
          options = ActiveAgent::Providers::CheaperInference::Options.new(api_key: "ci-explicit")

          assert_equal "ci-explicit", options.api_key
        end
      end

      # =====================================================================
      # Prompt
      # =====================================================================

      test "sends a prompt to the Cheaper Inference chat completions endpoint with the explicit key" do
        stub_chat_completion

        with_key_env("CHEAPER_INFERENCE_API_KEY" => "ci-env", "OPENAI_API_KEY" => "sk-openai-env") do
          prompt_provider(api_key: "ci-explicit").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer ci-explicit" })
      end

      test "sends a prompt with the CHEAPER_INFERENCE_API_KEY key when no explicit key is given" do
        stub_chat_completion

        with_key_env("CHEAPER_INFERENCE_API_KEY" => "ci-env") do
          prompt_provider.prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer ci-env" })
      end

      test "sends bare model ids unchanged" do
        stub_chat_completion

        with_key_env("CHEAPER_INFERENCE_API_KEY" => "ci-env") do
          prompt_provider(model: "gpt-5.4-mini").prompt
          prompt_provider(model: "gpt-5.4").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "gpt-5.4-mini" }
        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "gpt-5.4" }
      end

      # =====================================================================
      # Embeddings
      # =====================================================================

      test "sends an embedding request to the Cheaper Inference embeddings endpoint with the explicit key" do
        stub_request(:post, EMBEDDINGS_ENDPOINT).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: embedding_response.to_json
        )

        response = with_key_env("CHEAPER_INFERENCE_API_KEY" => "ci-env", "OPENAI_API_KEY" => "sk-openai-env") do
          ActiveAgent::Providers::CheaperInferenceProvider.new(
            service: "CheaperInference",
            model: "text-embedding-3-small",
            input: "hello",
            api_key: "ci-explicit"
          ).embed
        end

        assert_equal [ 0.1, 0.2 ], response.data.first[:embedding]
        assert_requested(:post, EMBEDDINGS_ENDPOINT, headers: { "Authorization" => "Bearer ci-explicit" })
      end

      private

      def prompt_provider(model: "gpt-5.4-mini", **credential)
        ActiveAgent::Providers::CheaperInferenceProvider.new(
          service: "CheaperInference",
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
          id: "chatcmpl-cheaperinference-request",
          object: "chat.completion",
          created: 1_700_000_000,
          model: "gpt-5.4-mini",
          choices: [ { index: 0, message: { role: "assistant", content: "Hello." }, finish_reason: "stop" } ],
          usage: { prompt_tokens: 3, completion_tokens: 2, total_tokens: 5 }
        }
      end

      def embedding_response
        {
          object: "list",
          model: "text-embedding-3-small",
          data: [ { object: "embedding", index: 0, embedding: [ 0.1, 0.2 ] } ],
          usage: { prompt_tokens: 2, total_tokens: 2 }
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
