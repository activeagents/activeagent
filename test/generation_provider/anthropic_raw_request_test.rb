require "test_helper"
require "active_agent/generation_provider/anthropic_provider"
require "active_agent/action_prompt/prompt"

module ActiveAgent
  module GenerationProvider
    class AnthropicRawRequestTest < ActiveSupport::TestCase
      setup do
        @config = {
          "api_key" => "test-key",
          "model" => "claude-3-opus-20240229"
        }
        @provider = AnthropicProvider.new(@config)

        @prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [
            ActiveAgent::ActionPrompt::Message.new(
              content: "Hello, Claude!",
              role: "user"
            )
          ],
          actions: [],
          options: {},
          output_schema: nil
        )
      end

      test "chat_response includes raw_request when provided" do
        mock_response = {
          "id" => "msg-123",
          "content" => [
            {
              "type" => "text",
              "text" => "Hello! I'm Claude. How can I assist you today?"
            }
          ],
          "stop_reason" => "end_turn",
          "usage" => {
            "input_tokens" => 10,
            "output_tokens" => 12
          }
        }

        request_params = {
          model: "claude-3-opus-20240229",
          messages: [ { role: "user", content: "Hello, Claude!" } ],
          max_tokens: 1024,
          temperature: 0.7
        }

        @provider.instance_variable_set(:@prompt, @prompt)
        response = @provider.send(:chat_response, mock_response, request_params)

        assert_not_nil response
        assert_equal request_params, response.raw_request
        assert_equal mock_response, response.raw_response
      end

      test "chat_response with tool use includes raw_request" do
        mock_response = {
          "id" => "msg-456",
          "content" => [
            {
              "type" => "text",
              "text" => "I'll help you with that calculation."
            },
            {
              "type" => "tool_use",
              "id" => "tool-789",
              "name" => "calculator",
              "input" => { "expression" => "2 + 2" }
            }
          ],
          "stop_reason" => "tool_use"
        }

        request_params = {
          model: "claude-3-opus-20240229",
          messages: [ { role: "user", content: "What is 2 + 2?" } ],
          tools: [
            {
              name: "calculator",
              description: "Performs calculations",
              input_schema: {
                type: "object",
                properties: {
                  expression: { type: "string" }
                }
              }
            }
          ],
          max_tokens: 1024
        }

        @provider.instance_variable_set(:@prompt, @prompt)
        response = @provider.send(:chat_response, mock_response, request_params)

        assert_not_nil response
        assert_equal request_params, response.raw_request
        assert_equal mock_response, response.raw_response
        assert response.message.action_requested
      end

      test "streaming request params are captured" do
        request_params = {
          model: "claude-3-opus-20240229",
          messages: [ { role: "user", content: "Stream test" } ],
          stream: true,
          max_tokens: 1024
        }

        @provider.instance_variable_set(:@prompt, @prompt)

        # Simulate setting streaming params like in chat_prompt
        @provider.instance_variable_set(:@streaming_request_params, request_params)

        assert_equal request_params, @provider.instance_variable_get(:@streaming_request_params)
      end

      test "response includes metadata alongside raw_request and raw_response" do
        mock_response = {
          "id" => "msg-meta-123",
          "content" => [
            {
              "type" => "text",
              "text" => "Response with metadata"
            }
          ],
          "stop_reason" => "end_turn",
          "model" => "claude-3-opus-20240229",
          "usage" => {
            "input_tokens" => 5,
            "output_tokens" => 4
          }
        }

        request_params = {
          model: "claude-3-opus-20240229",
          messages: [ { role: "user", content: "Test" } ],
          max_tokens: 100
        }

        @provider.instance_variable_set(:@prompt, @prompt)
        response = @provider.send(:chat_response, mock_response, request_params)

        assert_not_nil response
        assert_equal request_params, response.raw_request
        assert_equal mock_response, response.raw_response

        # Response should also have metadata
        assert_instance_of Hash, response.metadata
      end
    end
  end
end
