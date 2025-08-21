require "test_helper"
require "active_agent/generation_provider/response"
require "active_agent/action_prompt/prompt"
require "active_agent/action_prompt/message"

module ActiveAgent
  module GenerationProvider
    class ResponseTest < ActiveSupport::TestCase
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
      end

      test "initializes with raw_request parameter" do
        raw_request = {
          model: "gpt-4",
          messages: [ { role: "user", content: "Hello" } ],
          temperature: 0.7
        }

        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_request: raw_request
        )

        assert_equal raw_request, response.raw_request
        assert_equal @prompt, response.prompt
        assert_equal @message, response.message
      end

      test "raw_request is optional and defaults to nil" do
        response = Response.new(
          prompt: @prompt,
          message: @message
        )

        assert_nil response.raw_request
      end

      test "stores both raw_request and raw_response" do
        raw_request = {
          model: "gpt-4",
          messages: [ { role: "user", content: "Hello" } ]
        }

        raw_response = {
          "id" => "chatcmpl-123",
          "choices" => [
            {
              "message" => {
                "role" => "assistant",
                "content" => "Hello! How can I help you?"
              }
            }
          ],
          "usage" => {
            "prompt_tokens" => 10,
            "completion_tokens" => 8,
            "total_tokens" => 18
          }
        }

        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_request: raw_request,
          raw_response: raw_response
        )

        assert_equal raw_request, response.raw_request
        assert_equal raw_response, response.raw_response
      end

      test "usage helper methods work with raw_response" do
        raw_response = {
          "usage" => {
            "prompt_tokens" => 100,
            "completion_tokens" => 50,
            "total_tokens" => 150
          }
        }

        response = Response.new(
          prompt: @prompt,
          message: @message,
          raw_response: raw_response
        )

        assert_equal 100, response.prompt_tokens
        assert_equal 50, response.completion_tokens
        assert_equal 150, response.total_tokens
        assert_equal raw_response["usage"], response.usage
      end

      test "metadata can be set and accessed" do
        response = Response.new(
          prompt: @prompt,
          message: @message,
          metadata: { provider: "OpenAI", model_used: "gpt-4" }
        )

        assert_equal "OpenAI", response.metadata[:provider]
        assert_equal "gpt-4", response.metadata[:model_used]

        # Metadata is mutable
        response.metadata[:trace_id] = "trace-123"
        assert_equal "trace-123", response.metadata[:trace_id]
      end
    end
  end
end
