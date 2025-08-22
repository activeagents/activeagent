require "test_helper"
require "active_agent/generation_provider/response"
require "active_agent/action_prompt/prompt"
require "active_agent/action_prompt/message"

module ActiveAgent
  module GenerationProvider
    class ResponseSanitizationTest < ActiveSupport::TestCase
      setup do
        @prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [],
          actions: [],
          options: {},
          output_schema: nil
        )

        @message = ActiveAgent::ActionPrompt::Message.new(
          content: "Test response",
          role: "assistant"
        )

        # Mock the ActiveAgent config to set up sanitizers
        @original_config = ActiveAgent.config
        test_config = {
          "openai" => { "api_key" => "sk-test123secret" },
          "anthropic" => { "access_token" => "ant-test456token" }
        }
        ActiveAgent.instance_variable_set(:@config, test_config)
        ActiveAgent.sanitizers_reset!
      end

      teardown do
        ActiveAgent.instance_variable_set(:@config, @original_config)
        ActiveAgent.sanitizers_reset!
      end

      test "sanitizes API keys in raw_request" do
        raw_request = {
          model: "gpt-4",
          messages: [ { role: "user", content: "Hello" } ],
          api_key: "sk-test123secret",
          headers: {
            "Authorization" => "Bearer sk-test123secret"
          }
        }

        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_request: raw_request
        )

        # The API key should be replaced with a placeholder
        assert_equal "<OPENAI_API_KEY>", response.raw_request[:api_key]
        assert_equal "Bearer <OPENAI_API_KEY>", response.raw_request[:headers]["Authorization"]

        # Other fields should remain unchanged
        assert_equal "gpt-4", response.raw_request[:model]
        assert_equal [ { role: "user", content: "Hello" } ], response.raw_request[:messages]
      end

      test "sanitizes access tokens in nested structures" do
        raw_request = {
          model: "claude-3",
          config: {
            auth: {
              token: "ant-test456token",
              type: "bearer"
            }
          },
          headers: {
            "X-API-Key" => "ant-test456token"
          }
        }

        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_request: raw_request
        )

        # The access token should be replaced in nested hashes
        assert_equal "<ANTHROPIC_ACCESS_TOKEN>", response.raw_request[:config][:auth][:token]
        assert_equal "<ANTHROPIC_ACCESS_TOKEN>", response.raw_request[:headers]["X-API-Key"]
        assert_equal "bearer", response.raw_request[:config][:auth][:type]
      end

      test "sanitizes credentials in arrays" do
        raw_request = {
          model: "gpt-4",
          messages: [
            { role: "system", content: "You have API key: sk-test123secret" },
            { role: "user", content: "What's my token ant-test456token?" }
          ],
          tools: [
            { name: "api_call", api_key: "sk-test123secret" }
          ]
        }

        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_request: raw_request
        )

        # Credentials should be sanitized in array elements
        assert_equal "You have API key: <OPENAI_API_KEY>",
                     response.raw_request[:messages][0][:content]
        assert_equal "What's my token <ANTHROPIC_ACCESS_TOKEN>?",
                     response.raw_request[:messages][1][:content]
        assert_equal "<OPENAI_API_KEY>", response.raw_request[:tools][0][:api_key]
      end

      test "handles nil raw_request gracefully" do
        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_request: nil
        )

        assert_nil response.raw_request
      end

      test "handles non-hash raw_request gracefully" do
        # If for some reason raw_request is not a hash (unlikely but defensive)
        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_request: "string_request"
        )

        assert_equal "string_request", response.raw_request
      end

      test "does not modify original request object" do
        original_request = {
          model: "gpt-4",
          api_key: "sk-test123secret",
          messages: [ { role: "user", content: "Hello with key sk-test123secret" } ]
        }

        # Keep a copy of the original to verify it wasn't modified
        original_copy = original_request.deep_dup

        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_request: original_request
        )

        # Original should remain unchanged
        assert_equal original_copy, original_request
        assert_equal "sk-test123secret", original_request[:api_key]

        # But response.raw_request should be sanitized
        assert_equal "<OPENAI_API_KEY>", response.raw_request[:api_key]
      end

      test "sanitizes multiple different credentials" do
        raw_request = {
          openai_key: "sk-test123secret",
          anthropic_key: "ant-test456token",
          combined: "Keys: sk-test123secret and ant-test456token"
        }

        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_request: raw_request
        )

        assert_equal "<OPENAI_API_KEY>", response.raw_request[:openai_key]
        assert_equal "<ANTHROPIC_ACCESS_TOKEN>", response.raw_request[:anthropic_key]
        assert_equal "Keys: <OPENAI_API_KEY> and <ANTHROPIC_ACCESS_TOKEN>",
                     response.raw_request[:combined]
      end
    end
  end
end
