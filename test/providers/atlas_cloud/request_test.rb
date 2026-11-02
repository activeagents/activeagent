# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Atlas Cloud request tests"
  return
end

require_relative "../../../lib/active_agent/providers/atlas_cloud_provider"

module Providers
  module AtlasCloud
    class RequestTest < ActiveSupport::TestCase
      include WebMock::API

      CHAT_ENDPOINT = "https://api.atlascloud.ai/v1/chat/completions"

      test "sends a prompt to the Atlas Cloud chat completions endpoint with the explicit key" do
        stub_chat_completion

        with_key_env("ATLASCLOUD_API_KEY" => "atlas-env") do
          prompt_provider(api_key: "atlas-explicit").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer atlas-explicit" })
      end

      test "sends a prompt with the ATLASCLOUD_API_KEY key when no explicit key is given" do
        stub_chat_completion

        with_key_env("ATLASCLOUD_API_KEY" => "atlas-env") do
          prompt_provider.prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer atlas-env" })
      end

      test "sends the model id unchanged and returns the assistant message" do
        stub_chat_completion

        response = with_key_env("ATLASCLOUD_API_KEY" => "atlas-env") do
          prompt_provider.prompt
        end

        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "qwen/qwen3.8-max" }
        assert_equal "Hello.", response.message.content
      end

      test "honors a base_url override" do
        stub_request(:post, "https://proxy.example.com/v1/chat/completions").to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: chat_completion.to_json
        )

        with_key_env("ATLASCLOUD_API_KEY" => "atlas-env") do
          prompt_provider(base_url: "https://proxy.example.com/v1").prompt
        end

        assert_requested(:post, "https://proxy.example.com/v1/chat/completions")
        assert_not_requested(:post, CHAT_ENDPOINT)
      end

      private

      def prompt_provider(**credential)
        ActiveAgent::Providers::AtlasCloudProvider.new(
          service: "AtlasCloud",
          model: "qwen/qwen3.8-max",
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
          id: "chatcmpl-atlas-request",
          object: "chat.completion",
          created: 1_700_000_000,
          model: "qwen/qwen3.8-max",
          choices: [ { index: 0, message: { role: "assistant", content: "Hello." }, finish_reason: "stop" } ],
          usage: { prompt_tokens: 3, completion_tokens: 2, total_tokens: 5 }
        }
      end

      # Clears ATLASCLOUD_API_KEY and OPENAI_API_KEY, applies values on top,
      # and restores the original environment afterwards.
      def with_key_env(values = {})
        names = %w[ATLASCLOUD_API_KEY OPENAI_API_KEY] | values.keys
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
