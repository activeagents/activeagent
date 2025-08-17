require "test_helper"
require "active_agent/generation_provider/open_router_provider"
require "active_agent/action_prompt/prompt"
require "active_agent/generation_provider/response"

module ActiveAgent
  module GenerationProvider
    class OpenRouterProviderTest < ActiveSupport::TestCase
      setup do
        @base_config = {
          "api_key" => "test_api_key",
          "model" => "openai/gpt-4o",
          "app_name" => "TestApp",
          "site_url" => "https://test.app"
        }
      end

      test "initializes with basic configuration" do
        provider = OpenRouterProvider.new(@base_config)
        
        assert_equal "test_api_key", provider.instance_variable_get(:@access_token)
        assert_equal "openai/gpt-4o", provider.instance_variable_get(:@model_name)
        assert_equal "TestApp", provider.instance_variable_get(:@app_name)
        assert_equal "https://test.app", provider.instance_variable_get(:@site_url)
      end

      test "initializes with fallback models configuration" do
        config = @base_config.merge(
          "fallback_models" => ["anthropic/claude-3-opus", "google/gemini-pro"],
          "enable_fallbacks" => true
        )
        
        provider = OpenRouterProvider.new(config)
        
        assert_equal ["anthropic/claude-3-opus", "google/gemini-pro"], 
                     provider.instance_variable_get(:@fallback_models)
        assert provider.instance_variable_get(:@enable_fallbacks)
      end

      test "initializes with provider preferences" do
        config = @base_config.merge(
          "provider" => {
            "order" => ["OpenAI", "Anthropic"],
            "require_parameters" => true,
            "data_collection" => "deny"
          }
        )
        
        provider = OpenRouterProvider.new(config)
        prefs = provider.instance_variable_get(:@provider_preferences)
        
        assert_equal ["OpenAI", "Anthropic"], prefs["order"]
        assert prefs["require_parameters"]
        assert_equal "deny", prefs["data_collection"]
      end

      test "initializes with transforms" do
        config = @base_config.merge(
          "transforms" => ["middle-out"]
        )
        
        provider = OpenRouterProvider.new(config)
        
        assert_equal ["middle-out"], provider.instance_variable_get(:@transforms)
      end

      test "sets correct OpenRouter headers" do
        provider = OpenRouterProvider.new(@base_config)
        client = provider.instance_variable_get(:@client)
        
        assert_not_nil client
        # The client should be configured with OpenRouter base URL
        assert_equal "https://openrouter.ai/api/v1", client.instance_variable_get(:@uri_base)
      end

      test "supports_vision? returns true for vision models" do
        provider = OpenRouterProvider.new(@base_config)
        
        assert provider.supports_vision?("openai/gpt-4o")
        assert provider.supports_vision?("anthropic/claude-3-5-sonnet")
        assert provider.supports_vision?("google/gemini-pro-vision")
        
        refute provider.supports_vision?("meta-llama/llama-3-70b")
        refute provider.supports_vision?("openai/gpt-3.5-turbo")
      end

      test "supports_structured_output? returns true for compatible models" do
        provider = OpenRouterProvider.new(@base_config)
        
        assert provider.supports_structured_output?("openai/gpt-4o")
        assert provider.supports_structured_output?("openai/gpt-4-turbo")
        assert provider.supports_structured_output?("openai/gpt-3.5-turbo-1106")
        
        refute provider.supports_structured_output?("anthropic/claude-3-opus")
        refute provider.supports_structured_output?("google/gemini-pro")
      end

      test "builds OpenRouter-specific parameters with fallbacks" do
        config = @base_config.merge(
          "fallback_models" => ["anthropic/claude-3-opus"],
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
        
        assert_equal ["openai/gpt-4o", "anthropic/claude-3-opus"], params[:models]
        assert_equal "fallback", params[:route]
      end

      test "builds provider preferences correctly" do
        config = @base_config.merge(
          "enable_fallbacks" => true,
          "provider" => {
            "order" => ["OpenAI", "Anthropic"],
            "require_parameters" => true,
            "data_collection" => "deny"
          }
        )
        
        provider = OpenRouterProvider.new(config)
        prefs = provider.send(:build_provider_preferences)
        
        assert_equal ["OpenAI", "Anthropic"], prefs[:order]
        assert prefs[:require_parameters]
        assert prefs[:allow_fallbacks]
        assert_equal "deny", prefs[:data_collection]
      end

      test "data_collection parameter defaults to allow" do
        provider = OpenRouterProvider.new(@base_config)
        prefs = provider.send(:build_provider_preferences)
        
        assert_equal "allow", prefs[:data_collection]
      end

      test "data_collection parameter can be set to deny" do
        config = @base_config.merge("data_collection" => "deny")
        provider = OpenRouterProvider.new(config)
        prefs = provider.send(:build_provider_preferences)
        
        assert_equal "deny", prefs[:data_collection]
      end

      test "data_collection parameter can be array of provider names" do
        config = @base_config.merge("data_collection" => ["OpenAI", "Anthropic"])
        provider = OpenRouterProvider.new(config)
        prefs = provider.send(:build_provider_preferences)
        
        assert_equal ["OpenAI", "Anthropic"], prefs[:data_collection]
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

      test "top-level data_collection overrides provider preferences" do
        config = @base_config.merge(
          "data_collection" => "allow",
          "provider" => {
            "data_collection" => "deny"
          }
        )
        provider = OpenRouterProvider.new(config)
        prefs = provider.send(:build_provider_preferences)
        
        assert_equal "allow", prefs[:data_collection]
      end

      test "handles OpenRouter-specific errors" do
        provider = OpenRouterProvider.new(@base_config)
        
        # Test rate limit error
        error = StandardError.new("rate limit exceeded")
        assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
          provider.send(:handle_openrouter_error, error)
        end
        
        # Test insufficient credits error
        error = StandardError.new("insufficient credits")
        assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
          provider.send(:handle_openrouter_error, error)
        end
        
        # Test no provider error
        error = StandardError.new("no available provider")
        assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
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
        response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt)
        
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

      test "defaults enable_fallbacks to true" do
        provider = OpenRouterProvider.new(@base_config)
        assert provider.instance_variable_get(:@enable_fallbacks)
      end

      test "defaults track_costs to true" do
        provider = OpenRouterProvider.new(@base_config)
        assert provider.instance_variable_get(:@track_costs)
      end

      test "defaults route to fallback" do
        provider = OpenRouterProvider.new(@base_config)
        assert_equal "fallback", provider.instance_variable_get(:@route)
      end

      test "environment variables fallback for API key" do
        ENV["OPENROUTER_API_KEY"] = "env_api_key"
        
        config = @base_config.dup
        config.delete("api_key")
        
        provider = OpenRouterProvider.new(config)
        assert_equal "env_api_key", provider.instance_variable_get(:@access_token)
      ensure
        ENV.delete("OPENROUTER_API_KEY")
      end

      test "alternative environment variable for API key" do
        ENV["OPENROUTER_ACCESS_TOKEN"] = "env_access_token"
        
        config = @base_config.dup
        config.delete("api_key")
        
        provider = OpenRouterProvider.new(config)
        assert_equal "env_access_token", provider.instance_variable_get(:@access_token)
      ensure
        ENV.delete("OPENROUTER_ACCESS_TOKEN")
      end
    end
  end
end