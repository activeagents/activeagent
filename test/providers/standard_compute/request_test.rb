# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Standard Compute request tests"
  return
end

require_relative "../../../lib/active_agent/providers/standard_compute_provider"

module Providers
  module StandardCompute
    class RequestTest < ActiveSupport::TestCase
      include WebMock::API

      CHAT_ENDPOINT = "https://api.stdcmpt.com/v1/chat/completions"

      # Cleared around every test so a key in the developer's or the CI
      # environment cannot decide the outcome.
      KEY_ENV = %w[
        STANDARDCOMPUTE_API_KEY
        OPENAI_API_KEY
      ].freeze

      # =====================================================================
      # Options
      # =====================================================================

      test "falls back to STANDARDCOMPUTE_API_KEY when no explicit key is given" do
        with_key_env("STANDARDCOMPUTE_API_KEY" => "sc-env") do
          assert_equal "sc-env", ActiveAgent::Providers::StandardCompute::Options.new.api_key
        end
      end

      test "prefers an explicit api_key over STANDARDCOMPUTE_API_KEY" do
        with_key_env("STANDARDCOMPUTE_API_KEY" => "sc-env") do
          options = ActiveAgent::Providers::StandardCompute::Options.new(api_key: "sc-explicit")

          assert_equal "sc-explicit", options.api_key
        end
      end

      # =====================================================================
      # Prompt
      # =====================================================================

      test "sends a prompt to the Standard Compute chat completions endpoint with the explicit key" do
        stub_chat_completion

        with_key_env("STANDARDCOMPUTE_API_KEY" => "sc-env", "OPENAI_API_KEY" => "sk-openai-env") do
          prompt_provider(api_key: "sc-explicit").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer sc-explicit" })
      end

      test "sends a prompt with the STANDARDCOMPUTE_API_KEY key when no explicit key is given" do
        stub_chat_completion

        with_key_env("STANDARDCOMPUTE_API_KEY" => "sc-env") do
          prompt_provider.prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer sc-env" })
      end

      test "sends the routed model and pinned model ids unchanged" do
        stub_chat_completion

        with_key_env("STANDARDCOMPUTE_API_KEY" => "sc-env") do
          prompt_provider(model: "StandardCompute").prompt
          prompt_provider(model: "deepseek/deepseek-v4.1-flash").prompt
          prompt_provider(model: "z-ai/glm-5.3").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "StandardCompute" }
        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "deepseek/deepseek-v4.1-flash" }
        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "z-ai/glm-5.3" }
      end

      private

      def prompt_provider(model: "StandardCompute", **credential)
        ActiveAgent::Providers::StandardComputeProvider.new(
          service: "StandardCompute",
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
          id: "chatcmpl-standard-compute-request",
          object: "chat.completion",
          created: 1_700_000_000,
          model: "StandardCompute",
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
