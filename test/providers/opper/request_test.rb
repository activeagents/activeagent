# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Opper request tests"
  return
end

require_relative "../../../lib/active_agent/providers/opper_provider"

module Providers
  module Opper
    class RequestTest < ActiveSupport::TestCase
      include WebMock::API

      CHAT_ENDPOINT = "https://api.opper.ai/v3/compat/chat/completions"
      EMBEDDINGS_ENDPOINT = "https://api.opper.ai/v3/compat/embeddings"

      # Cleared around every test so a key in the developer's or the CI
      # environment cannot decide the outcome.
      KEY_ENV = %w[
        OPPER_API_KEY
        OPENAI_API_KEY
      ].freeze

      # =====================================================================
      # Options
      # =====================================================================

      test "falls back to OPPER_API_KEY when no explicit key is given" do
        with_key_env("OPPER_API_KEY" => "op-env") do
          assert_equal "op-env", ActiveAgent::Providers::Opper::Options.new.api_key
        end
      end

      test "prefers an explicit api_key over OPPER_API_KEY" do
        with_key_env("OPPER_API_KEY" => "op-env") do
          options = ActiveAgent::Providers::Opper::Options.new(api_key: "op-explicit")

          assert_equal "op-explicit", options.api_key
        end
      end

      # =====================================================================
      # Prompt
      # =====================================================================

      test "sends a prompt to the Opper chat completions endpoint with the explicit key" do
        stub_chat_completion

        with_key_env("OPPER_API_KEY" => "op-env", "OPENAI_API_KEY" => "sk-openai-env") do
          prompt_provider(api_key: "op-explicit").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer op-explicit" })
      end

      test "sends a prompt with the OPPER_API_KEY key when no explicit key is given" do
        stub_chat_completion

        with_key_env("OPPER_API_KEY" => "op-env") do
          prompt_provider.prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer op-env" })
      end

      test "sends pool and pinned model ids unchanged" do
        stub_chat_completion

        with_key_env("OPPER_API_KEY" => "op-env") do
          prompt_provider(model: "claude-sonnet-4-6").prompt
          prompt_provider(model: "anthropic/claude-sonnet-4-6").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "claude-sonnet-4-6" }
        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "anthropic/claude-sonnet-4-6" }
      end

      # =====================================================================
      # Embeddings
      # =====================================================================

      test "sends an embedding request to the Opper embeddings endpoint with the explicit key" do
        stub_request(:post, EMBEDDINGS_ENDPOINT).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: embedding_response.to_json
        )

        response = with_key_env("OPPER_API_KEY" => "op-env", "OPENAI_API_KEY" => "sk-openai-env") do
          ActiveAgent::Providers::OpperProvider.new(
            service: "Opper",
            model: "text-embedding-3-small",
            input: "hello",
            api_key: "op-explicit"
          ).embed
        end

        assert_equal [ 0.1, 0.2 ], response.data.first[:embedding]
        assert_requested(:post, EMBEDDINGS_ENDPOINT, headers: { "Authorization" => "Bearer op-explicit" })
      end

      private

      def prompt_provider(model: "claude-sonnet-4-6", **credential)
        ActiveAgent::Providers::OpperProvider.new(
          service: "Opper",
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
          id: "chatcmpl-opper-request",
          object: "chat.completion",
          created: 1_700_000_000,
          model: "claude-sonnet-4-6",
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
