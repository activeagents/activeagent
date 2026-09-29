# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/_base_provider"
# Required up front so every test can run independently of the loading tests
# below, which would otherwise have to run first (test order is randomized).
require "active_agent/providers/deepseek_provider"

module Providers
  module DeepSeek
    class DeepSeekProviderTest < ActiveSupport::TestCase
      test "loads DeepSeekProvider via the deepseek path" do
        require "active_agent/providers/deepseek_provider"

        assert defined?(ActiveAgent::Providers::DeepSeekProvider)
        assert defined?(ActiveAgent::Providers::DeepSeek::Options)
        assert defined?(ActiveAgent::Providers::DeepSeek::Chat::Request)
      end

      # `service: "DeepSeek"` underscores to "deep_seek", so provider_load looks
      # for a differently-named file than `:deepseek` does.
      test "loads DeepSeekProvider via the deep_seek path" do
        require "active_agent/providers/deep_seek_provider"

        assert defined?(ActiveAgent::Providers::DeepSeekProvider)
      end

      test "resolves both the :deepseek reference and the service name" do
        assert_equal ActiveAgent::Providers::DeepSeekProvider, ActiveAgent::Base.provider_load("Deepseek")
        assert_equal ActiveAgent::Providers::DeepSeekProvider, ActiveAgent::Base.provider_load("DeepSeek")
      end

      test "reports the brand-cased service name" do
        assert_equal "DeepSeek", ActiveAgent::Providers::DeepSeekProvider.service_name
      end

      test "accepts its own service name" do
        provider = ActiveAgent::Providers::DeepSeekProvider.new(
          service: "DeepSeek", api_key: "test", messages: [ { role: "user", content: "hi" } ]
        )

        assert_equal "DeepSeek", provider.service_name
      end

      test "rejects another provider's service name" do
        assert_raises(RuntimeError) do
          ActiveAgent::Providers::DeepSeekProvider.new(
            service: "Anthropic", api_key: "test", messages: [ { role: "user", content: "hi" } ]
          )
        end
      end

      # =====================================================================
      # Options
      # =====================================================================

      test "defaults base_url to the OpenAI-compatible endpoint" do
        options = ActiveAgent::Providers::DeepSeek::Options.new(api_key: "test")

        assert_equal "https://api.deepseek.com", options.base_url
      end

      test "keeps an explicit base_url" do
        options = ActiveAgent::Providers::DeepSeek::Options.new(
          api_key: "test", base_url: "https://proxy.internal"
        )

        assert_equal "https://proxy.internal", options.base_url
      end

      test "resolves the api key from DEEPSEEK_API_KEY" do
        with_env("DEEPSEEK_API_KEY" => "from-env") do
          options = ActiveAgent::Providers::DeepSeek::Options.new

          assert_equal "from-env", options.api_key
        end
      end

      test "prefers an explicit api key over the environment" do
        with_env("DEEPSEEK_API_KEY" => "from-env") do
          options = ActiveAgent::Providers::DeepSeek::Options.new(api_key: "explicit")

          assert_equal "explicit", options.api_key
        end
      end

      # DeepSeek has no organization or project scoping; inheriting OpenAI's
      # OPENAI_ORG_ID fallback would attach a foreign identifier to requests.
      test "leaves organization and project unset" do
        with_env("OPENAI_ORG_ID" => "org-should-not-leak", "OPENAI_PROJECT_ID" => "proj-should-not-leak") do
          options = ActiveAgent::Providers::DeepSeek::Options.new(api_key: "test")

          assert_nil options.organization
          assert_nil options.project
        end
      end

      # =====================================================================
      # Request
      # =====================================================================

      test "defaults the model to deepseek-flash" do
        request = request_for(messages: [ { role: "user", content: "hi" } ])

        assert_equal "deepseek-flash", request.serialize[:model]
      end

      test "keeps an explicit model" do
        request = request_for(model: "deepseek-v4-pro", messages: [ { role: "user", content: "hi" } ])

        assert_equal "deepseek-v4-pro", request.serialize[:model]
      end

      # DeepSeek's API decides how DeepSeek behaves — including whether thinking
      # runs — so the provider must not invent a default of its own.
      test "leaves thinking to DeepSeek's default" do
        request = request_for(messages: [ { role: "user", content: "hi" } ])

        assert_not request.serialize.key?(:thinking)
      end

      test "passes an explicit thinking setting through untouched" do
        request = request_for(
          messages: [ { role: "user", content: "hi" } ],
          thinking: { type: "disabled" }
        )

        assert_equal({ type: "disabled" }, request.serialize[:thinking])
      end

      test "passes response_format through for native JSON output" do
        request = request_for(
          messages:         [ { role: "user", content: "hi" } ],
          response_format:  { type: "json_object" }
        )

        assert_equal({ type: "json_object" }, request.serialize[:response_format])
      end

      test "does not leak thinking into the OpenAI request class" do
        request = ActiveAgent::Providers::OpenAI::Chat::Request.new(
          model: "gpt-4", messages: [ { role: "user", content: "hi" } ]
        )

        assert_not request.serialize.key?(:thinking)
      end

      private

      def request_for(**params)
        ActiveAgent::Providers::DeepSeek::Chat::RequestType.new.cast(params)
      end

      def with_env(values)
        previous = values.keys.to_h { |key| [ key, ENV[key] ] }
        values.each { |key, value| ENV[key] = value }
        yield
      ensure
        previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end
    end
  end
end
