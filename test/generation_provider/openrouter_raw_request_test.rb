require "test_helper"
require "active_agent/generation_provider/open_router_provider"
require "active_agent/action_prompt/prompt"

module ActiveAgent
  module GenerationProvider
    class OpenRouterRawRequestTest < ActiveSupport::TestCase
      setup do
        @config = {
          "api_key" => "test-key",
          "model" => "openai/gpt-4",
          "app_name" => "TestApp",
          "site_url" => "https://test.app"
        }
        @provider = OpenRouterProvider.new(@config)

        @prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [
            ActiveAgent::ActionPrompt::Message.new(
              content: "Hello, OpenRouter!",
              role: "user"
            )
          ],
          actions: [],
          options: {},
          output_schema: nil
        )
      end

      test "inherits raw_request handling from OpenAI provider" do
        mock_response = {
          "id" => "gen-123",
          "choices" => [
            {
              "message" => {
                "role" => "assistant",
                "content" => "Hello from OpenRouter!"
              }
            }
          ],
          "model" => "openai/gpt-4"
        }

        request_params = {
          model: "openai/gpt-4",
          messages: [ { role: "user", content: "Hello, OpenRouter!" } ],
          temperature: 0.7,
          provider: {
            data_collection: "allow",
            allow_fallbacks: true
          }
        }

        @provider.instance_variable_set(:@prompt, @prompt)
        response = @provider.send(:chat_response, mock_response, request_params)

        assert_not_nil response
        assert_equal request_params, response.raw_request
        assert_equal mock_response, response.raw_response
        assert_instance_of ActiveAgent::GenerationProvider::Response, response
      end

      test "raw_request includes OpenRouter-specific parameters" do
        mock_response = {
          "id" => "gen-456",
          "choices" => [
            {
              "message" => {
                "role" => "assistant",
                "content" => "Response with fallback"
              }
            }
          ],
          "model" => "anthropic/claude-3-opus"
        }

        request_params = {
          model: "openai/gpt-4",
          models: [ "openai/gpt-4", "anthropic/claude-3-opus" ],
          route: "fallback",
          messages: [ { role: "user", content: "Test with fallbacks" } ],
          provider: {
            order: [ "OpenAI", "Anthropic" ],
            data_collection: "deny",
            allow_fallbacks: true
          }
        }

        @provider.instance_variable_set(:@prompt, @prompt)
        response = @provider.send(:chat_response, mock_response, request_params)

        assert_not_nil response.raw_request
        assert_equal [ "openai/gpt-4", "anthropic/claude-3-opus" ], response.raw_request[:models]
        assert_equal "fallback", response.raw_request[:route]
        assert_equal "deny", response.raw_request[:provider][:data_collection]
      end
    end
  end
end
