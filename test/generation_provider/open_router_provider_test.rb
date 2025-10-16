require "test_helper"
require "active_agent/providers/open_router_provider"
require "active_agent/action_prompt/prompt"
require "active_agent/providers/response"

module ActiveAgent
  module Providers
    class OpenRouterProviderTest < ActiveSupport::TestCase
      setup do
        @base_config = {
          "api_key" => "test_api_key",
          "model" => "openai/gpt-4o",
          "app_name" => "TestApp",
          "site_url" => "https://test.app"
        }
      end

      test "provider requires openai gem" do
        provider_file_path = File.join(Rails.root, "../../lib/active_agent/providers/open_router_provider.rb")
        provider_source    = File.read(provider_file_path)

        assert_includes provider_source, "require_gem!(:openai, __FILE__)"
      end

      test "initializes with basic configuration" do
        provider = OpenRouterProvider.new(@base_config)

        assert_equal "test_api_key", provider.instance_variable_get(:@options).access_token
        assert_equal "openai/gpt-4o", provider.instance_variable_get(:@options).model
        assert_equal "TestApp", provider.instance_variable_get(:@options).app_name
        assert_equal "https://test.app", provider.instance_variable_get(:@options).site_url
      end

      test "initializes with fallback models configuration" do
        config = @base_config.merge(
          "fallback_models" => [ "anthropic/claude-3-opus", "google/gemini-pro" ],
          "enable_fallbacks" => true
        )

        provider = OpenRouterProvider.new(config)

        assert_equal [ "anthropic/claude-3-opus", "google/gemini-pro" ],
                     provider.instance_variable_get(:@options).models
        assert provider.instance_variable_get(:@options).provider.allow_fallbacks
      end

      test "initializes with provider preferences" do
        config = @base_config.merge(
          "provider" => {
            "order" => [ "OpenAI", "Anthropic" ],
            "require_parameters" => true,
            "data_collection" => "deny"
          }
        )

        provider = OpenRouterProvider.new(config)
        prefs = provider.instance_variable_get(:@options).provider

        assert_equal [ "OpenAI", "Anthropic" ], prefs.order
        assert prefs.require_parameters
        assert_equal "deny", prefs.data_collection
      end

      test "initializes with transforms" do
        config = @base_config.merge(
          "transforms" => [ "middle-out" ]
        )

        provider = OpenRouterProvider.new(config)

        assert_equal [ "middle-out" ], provider.instance_variable_get(:@options).transforms
      end

      test "sets correct OpenRouter headers" do
        provider = OpenRouterProvider.new(@base_config)

        assert_not_nil provider.client
        # The client should be configured with OpenRouter base URL
        assert_equal "https://openrouter.ai/api/v1", provider.client.instance_variable_get(:@uri_base)

        # Verify extra headers are set
        extra_headers = provider.client.instance_variable_get(:@extra_headers)
        assert_not_nil extra_headers
        assert_equal "TestApp", extra_headers["x-title"]
        assert_equal "https://test.app", extra_headers["http-referer"]
      end

      test "uses default app name when not configured" do
        config = @base_config.dup
        config.delete("app_name")

        provider = OpenRouterProvider.new(config)
        extra_headers = provider.client.instance_variable_get(:@extra_headers)

        # Should use Rails app name or "ActiveAgent" as default
        assert_not_nil extra_headers["x-title"]
        assert_includes [ "ActiveAgent", "Dummy" ], extra_headers["x-title"]
      end

      test "uses default site URL from Rails config when not provided" do
        config = @base_config.dup
        config.delete("site_url")

        provider = OpenRouterProvider.new(config)
        client = provider.client
        extra_headers = client.instance_variable_get(:@extra_headers)

        # Should either be localhost or no http-referer header
        referer = extra_headers["http-referer"]
        assert(referer.nil? || referer.include?("localhost") || referer.include?("example.com"))
      end

      test "headers are present when both app_name and site_url are configured" do
        provider = OpenRouterProvider.new(@base_config)
        headers = provider.instance_variable_get(:@options).send(:client_options_extra_headers)

        assert_equal "TestApp", headers["x-title"]
        assert_equal "https://test.app", headers["http-referer"]
      end

      test "headers handle nil app_name gracefully" do
        config = @base_config.merge("app_name" => nil)
        provider = OpenRouterProvider.new(config)
        headers = provider.instance_variable_get(:@options).send(:client_options_extra_headers)

        # Should still have a header, using default
        assert_not_nil headers["x-title"]
      end

      test "headers handle nil site_url gracefully" do
        config = @base_config.merge("site_url" => nil)
        provider = OpenRouterProvider.new(config)
        headers = provider.instance_variable_get(:@options).send(:client_options_extra_headers)

        # http-referer might be nil or use default
        # The key should exist but value might be nil
        assert headers.key?("http-referer")
      end

      test "headers are passed to OpenAI client on initialization" do
        provider = OpenRouterProvider.new(@base_config)

        # The OpenAI::Client should receive the extra_headers
        assert_not_nil provider.client
        extra_headers = provider.client.instance_variable_get(:@extra_headers)

        assert_equal({
          "x-title" => "TestApp",
          "http-referer" => "https://test.app"
        }, extra_headers)
      end

      test "builds OpenRouter-specific parameters with fallbacks" do
        config = @base_config.merge(
          "fallback_models" => [ "anthropic/claude-3-opus" ],
          "route" => "fallback"
        )

        provider = OpenRouterProvider.new(config)

        # Create a real prompt object
        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [],
          actions: [],
          options: {},
          output_schema: nil
        )

        provider.instance_variable_set(:@prompt, prompt)

        params = provider.send(:build_openrouter_parameters)

        assert_equal "openai/gpt-4o", params[:model]
        assert_equal [ "anthropic/claude-3-opus" ], params[:models]
        assert_equal "fallback", params[:route]
      end

      test "builds provider preferences correctly" do
        config = @base_config.merge(
          "enable_fallbacks" => true,
          "provider" => {
            "order" => [ "OpenAI", "Anthropic" ],
            "require_parameters" => true,
            "data_collection" => "deny"
          }
        )

        provider = OpenRouterProvider.new(config)
        prefs = provider.send(:build_provider_preferences)

        assert_equal [ "OpenAI", "Anthropic" ], prefs[:order]
        assert prefs[:require_parameters]
        assert prefs[:allow_fallbacks]
        assert_equal "deny", prefs[:data_collection]
      end

      test "data_collection parameter defaults to nil" do
        provider = OpenRouterProvider.new(@base_config)
        prefs = provider.send(:build_provider_preferences)

        assert_nil prefs[:data_collection]
      end

      test "data_collection parameter can be set to deny" do
        config = @base_config.merge("data_collection" => "deny")
        provider = OpenRouterProvider.new(config)
        prefs = provider.send(:build_provider_preferences)

        assert_equal "deny", prefs[:data_collection]
      end

      test "data_collection parameter can be set in provider preferences" do
        config = @base_config.merge(
          "provider" => {
            "data_collection" => "deny"
          }
        )
        provider = OpenRouterProvider.new(config)
        prefs = provider.send(:build_provider_preferences)

        assert_equal "deny", prefs[:data_collection]
      end

      test "handles OpenRouter-specific errors" do
        provider = OpenRouterProvider.new(@base_config)

        # Test rate limit error
        error = StandardError.new("rate limit exceeded")
        assert_raises(ActiveAgent::Providers::BaseProvider::ProvidersError) do
          provider.send(:handle_openrouter_error, error)
        end

        # Test insufficient credits error
        error = StandardError.new("insufficient credits")
        assert_raises(ActiveAgent::Providers::BaseProvider::ProvidersError) do
          provider.send(:handle_openrouter_error, error)
        end

        # Test no provider error
        error = StandardError.new("no available provider")
        assert_raises(ActiveAgent::Providers::BaseProvider::ProvidersError) do
          provider.send(:handle_openrouter_error, error)
        end
      end

      test "tracks usage when enabled" do
        config = @base_config.merge("track_costs" => true)
        provider = OpenRouterProvider.new(config)

        response = {
          "usage" => {
            "prompt_tokens" => 100,
            "completion_tokens" => 50,
            "total_tokens" => 150
          },
          "model" => "openai/gpt-4o"
        }

        cost_info = provider.send(:track_usage, response)

        assert_equal "openai/gpt-4o", cost_info[:model]
        assert_equal 100, cost_info[:prompt_tokens]
        assert_equal 50, cost_info[:completion_tokens]
        assert_equal 150, cost_info[:total_tokens]
      end

      test "does not track usage when disabled" do
        config = @base_config.merge("track_costs" => false)
        provider = OpenRouterProvider.new(config)

        response = {
          "usage" => {
            "prompt_tokens" => 100,
            "completion_tokens" => 50,
            "total_tokens" => 150
          }
        }

        # Should return nil when tracking is disabled
        assert_nil provider.send(:track_usage, response)
      end

      test "adds metadata from response headers" do
        provider = OpenRouterProvider.new(@base_config)

        # Create a real response object with a minimal prompt
        prompt = ActiveAgent::ActionPrompt::Prompt.new(message: "test")
        response = ActiveAgent::Providers::Response.new(prompt: prompt)

        headers = {
          "x-provider" => "OpenAI",
          "x-model" => "gpt-4o",
          "x-trace-id" => "trace-123",
          "x-ratelimit-requests-limit" => "100",
          "x-ratelimit-requests-remaining" => "99"
        }

        provider.send(:add_openrouter_metadata, response, headers)

        # Verify metadata was set correctly
        assert_equal "OpenAI", response.metadata[:provider]
        assert_equal "gpt-4o", response.metadata[:model_used]
        assert_equal "trace-123", response.metadata[:trace_id]
        assert_equal "100", response.metadata[:ratelimit][:requests_limit]
        assert_equal "99", response.metadata[:ratelimit][:requests_remaining]
      end

      test "defaults enable_fallbacks to nil" do
        provider = OpenRouterProvider.new(@base_config)
        assert_nil provider.instance_variable_get(:@options).provider&.allow_fallbacks
      end

      test "defaults track_costs to true" do
        provider = OpenRouterProvider.new(@base_config)
        assert provider.instance_variable_get(:@track_costs)
      end

      test "defaults route to fallback" do
        provider = OpenRouterProvider.new(@base_config)
        assert_equal "fallback", provider.instance_variable_get(:@options).route
      end

      test "environment variables fallback for API key" do
        ENV["OPENROUTER_API_KEY"] = "env_api_key"

        config = @base_config.dup
        config.delete("api_key")

        provider = OpenRouterProvider.new(config)
        assert_equal "env_api_key", provider.instance_variable_get(:@options).access_token
      ensure
        ENV.delete("OPENROUTER_API_KEY")
      end

      test "alternative environment variable for API key" do
        ENV["OPENROUTER_ACCESS_TOKEN"] = "env_access_token"

        config = @base_config.dup
        config.delete("api_key")

        provider = OpenRouterProvider.new(config)
        assert_equal "env_access_token", provider.instance_variable_get(:@options).access_token
      ensure
        ENV.delete("OPENROUTER_ACCESS_TOKEN")
      end

      test "initializes with only providers configuration" do
        config = @base_config.merge("only" => [ "openai", "anthropic" ])
        provider = OpenRouterProvider.new(config)

        assert_equal [ "openai", "anthropic" ], provider.instance_variable_get(:@options).provider.only
      end

      test "initializes with ignore providers configuration" do
        config = @base_config.merge("ignore" => [ "google", "cohere" ])
        provider = OpenRouterProvider.new(config)

        assert_equal [ "google", "cohere" ], provider.instance_variable_get(:@options).provider.ignore
      end

      test "initializes with quantizations configuration" do
        config = @base_config.merge("quantizations" => [ "int4", "int8" ])
        provider = OpenRouterProvider.new(config)

        assert_equal [ "int4", "int8" ], provider.instance_variable_get(:@options).provider.quantizations
      end

      test "initializes with sort configuration" do
        config = @base_config.merge("sort" => "price")
        provider = OpenRouterProvider.new(config)

        assert_equal "price", provider.instance_variable_get(:@options).provider.sort
      end

      test "initializes with max_price configuration" do
        max_price = { "prompt_tokens" => 0.001, "completion_tokens" => 0.002 }
        config = @base_config.merge("max_price" => max_price)
        provider = OpenRouterProvider.new(config)

        assert_equal({ prompt: 0.001, completion: 0.002 }, provider.instance_variable_get(:@options).provider.max_price.to_h)
      end

      test "initializes with provider preferences containing new options" do
        config = @base_config.merge(
          "provider" => {
            "only" => [ "openai", "anthropic" ],
            "ignore" => [ "google" ],
            "quantizations" => [ "int4" ],
            "sort" => "throughput",
            "max_price" => { "prompt_tokens" => 0.001 }
          }
        )

        provider = OpenRouterProvider.new(config)
        prefs = provider.instance_variable_get(:@options).provider_parameters

        assert_equal [ "openai", "anthropic" ], prefs[:only]
        assert_equal [ "google" ], prefs[:ignore]
        assert_equal [ "int4" ], prefs[:quantizations]
        assert_equal "throughput", prefs[:sort]
        assert_equal({ prompt: 0.001 }, prefs[:max_price].to_h)
      end

      test "builds provider preferences with only providers" do
        config = @base_config.merge("only" => [ "openai", "anthropic" ])
        provider = OpenRouterProvider.new(config)

        # Create a real prompt object
        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [], actions: [], options: {}, output_schema: nil
        )
        provider.instance_variable_set(:@prompt, prompt)

        prefs = provider.send(:build_provider_preferences)
        assert_equal [ "openai", "anthropic" ], prefs[:only]
      end

      test "builds provider preferences with ignore providers" do
        config = @base_config.merge("ignore" => [ "google", "cohere" ])
        provider = OpenRouterProvider.new(config)

        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [], actions: [], options: {}, output_schema: nil
        )
        provider.instance_variable_set(:@prompt, prompt)

        prefs = provider.send(:build_provider_preferences)
        assert_equal [ "google", "cohere" ], prefs[:ignore]
      end

      test "builds provider preferences with quantizations" do
        config = @base_config.merge("quantizations" => [ "int4", "int8" ])
        provider = OpenRouterProvider.new(config)

        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [], actions: [], options: {}, output_schema: nil
        )
        provider.instance_variable_set(:@prompt, prompt)

        prefs = provider.send(:build_provider_preferences)
        assert_equal [ "int4", "int8" ], prefs[:quantizations]
      end

      test "builds provider preferences with sort" do
        config = @base_config.merge("sort" => "price")
        provider = OpenRouterProvider.new(config)

        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [], actions: [], options: {}, output_schema: nil
        )
        provider.instance_variable_set(:@prompt, prompt)

        prefs = provider.send(:build_provider_preferences)
        assert_equal "price", prefs[:sort]
      end

      test "builds provider preferences with max_price" do
        max_price = { "prompt_tokens" => 0.001, "completion_tokens" => 0.002 }
        config = @base_config.merge("max_price" => max_price)
        provider = OpenRouterProvider.new(config)

        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [], actions: [], options: {}, output_schema: nil
        )
        provider.instance_variable_set(:@prompt, prompt)

        prefs = provider.send(:build_provider_preferences)
        assert_equal({ prompt: 0.001, completion: 0.002 }, prefs[:max_price])
      end

      test "runtime options override configured provider preferences" do
        config = @base_config.merge(
          "only" => [ "openai" ],
          "sort" => "price"
        )
        provider = OpenRouterProvider.new(config)

        # Create prompt with runtime overrides
        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [],
          actions: [],
          options: {
            only: [ "anthropic", "openai" ],
            sort: "throughput",
            quantizations: [ "int4" ]
          },
          output_schema: nil
        )
        provider.instance_variable_set(:@prompt, prompt)

        prefs = provider.send(:build_provider_preferences)

        # Runtime options should override configured ones
        assert_equal [ "anthropic", "openai" ], prefs[:only]
        assert_equal "throughput", prefs[:sort]
        assert_equal [ "int4" ], prefs[:quantizations]
      end

      test "builds openrouter parameters with all provider preferences" do
        config = @base_config.merge(
          "only" => [ "openai", "anthropic" ],
          "ignore" => [ "google" ],
          "quantizations" => [ "int4" ],
          "sort" => "price",
          "max_price" => { "prompt_tokens" => 0.001 }
        )

        provider = OpenRouterProvider.new(config)

        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [], actions: [], options: {}, output_schema: nil
        )
        provider.instance_variable_set(:@prompt, prompt)

        params = provider.send(:build_openrouter_parameters)

        assert params[:provider].present?
        assert_equal [ "openai", "anthropic" ], params[:provider][:only]
        assert_equal [ "google" ], params[:provider][:ignore]
        assert_equal [ "int4" ], params[:provider][:quantizations]
        assert_equal "price", params[:provider][:sort]
        assert_equal({ prompt: 0.001 }, params[:provider][:max_price])
      end
    end
  end
end
