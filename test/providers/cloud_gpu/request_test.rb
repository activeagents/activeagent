# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping CloudGPU request tests"
  return
end

require_relative "../../../lib/active_agent/providers/cloud_gpu_provider"

module Providers
  module CloudGPU
    class RequestTest < ActiveSupport::TestCase
      include WebMock::API

      CHAT_ENDPOINT = "https://cloudgpu.app/v1/chat/completions"

      # Cleared around every test so a key in the developer's or the CI
      # environment cannot decide the outcome.
      KEY_ENV = %w[
        CLOUDGPU_API_KEY
        OPENAI_API_KEY
      ].freeze

      # =====================================================================
      # Options
      # =====================================================================

      test "falls back to CLOUDGPU_API_KEY when no explicit key is given" do
        with_key_env("CLOUDGPU_API_KEY" => "cg-env") do
          assert_equal "cg-env", ActiveAgent::Providers::CloudGPU::Options.new.api_key
        end
      end

      test "prefers an explicit api_key over CLOUDGPU_API_KEY" do
        with_key_env("CLOUDGPU_API_KEY" => "cg-env") do
          options = ActiveAgent::Providers::CloudGPU::Options.new(api_key: "cg-explicit")

          assert_equal "cg-explicit", options.api_key
        end
      end

      # =====================================================================
      # Prompt
      # =====================================================================

      test "sends a prompt to the CloudGPU chat completions endpoint with the explicit key" do
        stub_chat_completion

        with_key_env("CLOUDGPU_API_KEY" => "cg-env", "OPENAI_API_KEY" => "sk-openai-env") do
          prompt_provider(api_key: "cg-explicit").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer cg-explicit" })
      end

      test "sends a prompt with the CLOUDGPU_API_KEY key when no explicit key is given" do
        stub_chat_completion

        with_key_env("CLOUDGPU_API_KEY" => "cg-env") do
          prompt_provider.prompt
        end

        assert_requested(:post, CHAT_ENDPOINT, headers: { "Authorization" => "Bearer cg-env" })
      end

      test "sends model ids unchanged" do
        stub_chat_completion

        with_key_env("CLOUDGPU_API_KEY" => "cg-env") do
          prompt_provider(model: "deepseek-v4-flash").prompt
          prompt_provider(model: "glm-5.3").prompt
        end

        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "deepseek-v4-flash" }
        assert_requested(:post, CHAT_ENDPOINT) { |request| JSON.parse(request.body)["model"] == "glm-5.3" }
      end

      private

      def prompt_provider(model: "deepseek-v4-flash", **credential)
        ActiveAgent::Providers::CloudGPUProvider.new(
          service: "CloudGPU",
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
          id: "chatcmpl-cloudgpu-request",
          object: "chat.completion",
          created: 1_700_000_000,
          model: "deepseek-v4-flash",
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
