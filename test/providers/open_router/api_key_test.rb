# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenRouter API key tests"
  return
end

require_relative "../../../lib/active_agent/providers/open_router_provider"

module Providers
  module OpenRouter
    class ApiKeyTest < ActiveSupport::TestCase
      include WebMock::API

      ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

      # Every variable OpenRouter::Options reads, plus the one the openai gem
      # reads when the client is built without a key.
      KEY_ENV = %w[
        OPENROUTER_API_KEY
        OPEN_ROUTER_API_KEY
        OPENROUTER_ACCESS_TOKEN
        OPEN_ROUTER_ACCESS_TOKEN
        OPENAI_API_KEY
      ].freeze

      # =====================================================================
      # Options
      # =====================================================================

      test "keeps an explicit api_key when no environment key is set" do
        with_key_env do
          options = ActiveAgent::Providers::OpenRouter::Options.new(api_key: "sk-or-explicit")

          assert_equal "sk-or-explicit", options.api_key
        end
      end

      test "prefers an explicit api_key over OPENROUTER_API_KEY" do
        with_key_env("OPENROUTER_API_KEY" => "sk-or-env") do
          options = ActiveAgent::Providers::OpenRouter::Options.new(api_key: "sk-or-explicit")

          assert_equal "sk-or-explicit", options.api_key
        end
      end

      test "prefers an explicit access_token over OPENROUTER_API_KEY" do
        with_key_env("OPENROUTER_API_KEY" => "sk-or-env") do
          options = ActiveAgent::Providers::OpenRouter::Options.new(access_token: "sk-or-explicit")

          assert_equal "sk-or-explicit", options.api_key
        end
      end

      test "prefers an explicit api_key given under a string key" do
        with_key_env("OPENROUTER_API_KEY" => "sk-or-env") do
          options = ActiveAgent::Providers::OpenRouter::Options.new("api_key" => "sk-or-explicit")

          assert_equal "sk-or-explicit", options.api_key
        end
      end

      test "prefers an explicit api_key over every environment fallback" do
        env = KEY_ENV.to_h { |name| [ name, "#{name.downcase}-value" ] }

        with_key_env(env) do
          options = ActiveAgent::Providers::OpenRouter::Options.new(api_key: "sk-or-explicit")

          assert_equal "sk-or-explicit", options.api_key
        end
      end

      test "falls back to the environment variables in order" do
        with_key_env("OPEN_ROUTER_API_KEY" => "second", "OPENROUTER_ACCESS_TOKEN" => "third") do
          assert_equal "second", ActiveAgent::Providers::OpenRouter::Options.new.api_key
        end

        with_key_env("OPEN_ROUTER_ACCESS_TOKEN" => "fourth") do
          assert_equal "fourth", ActiveAgent::Providers::OpenRouter::Options.new.api_key
        end
      end

      # =====================================================================
      # Request
      # =====================================================================

      test "sends an explicit api_key to OpenRouter when the environment has keys" do
        assert_request_authorized_with(api_key: "sk-or-explicit")
      end

      test "sends an explicit access_token to OpenRouter when the environment has keys" do
        assert_request_authorized_with(access_token: "sk-or-explicit")
      end

      private

      def assert_request_authorized_with(**credential)
        stub_request(:post, ENDPOINT).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: chat_completion.to_json
        )

        with_key_env("OPENROUTER_API_KEY" => "sk-or-env", "OPENAI_API_KEY" => "sk-openai-env") do
          ActiveAgent::Providers::OpenRouterProvider.new(
            service: "OpenRouter",
            model: "openai/gpt-4o-mini",
            messages: [ { role: "user", content: "hi" } ],
            **credential
          ).prompt
        end

        assert_requested(:post, ENDPOINT, headers: { "Authorization" => "Bearer sk-or-explicit" })
      end

      def chat_completion
        {
          id: "chatcmpl-openrouter-key",
          object: "chat.completion",
          created: 1_700_000_000,
          model: "openai/gpt-4o-mini",
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
