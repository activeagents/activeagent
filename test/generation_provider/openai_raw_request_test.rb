require "test_helper"
require "active_agent/generation_provider/open_ai_provider"
require "active_agent/action_prompt/prompt"

module ActiveAgent
  module GenerationProvider
    class OpenAIRawRequestTest < ActiveSupport::TestCase
      setup do
        @config = {
          "api_key" => "test-key",
          "model" => "gpt-4"
        }
        @provider = OpenAIProvider.new(@config)

        @prompt = ActiveAgent::ActionPrompt::Prompt.new(
          messages: [
            ActiveAgent::ActionPrompt::Message.new(
              content: "Hello, world!",
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
          "id" => "chatcmpl-123",
          "choices" => [
            {
              "message" => {
                "role" => "assistant",
                "content" => "Hello! How can I help you today?"
              }
            }
          ]
        }

        request_params = {
          model: "gpt-4",
          messages: [ { role: "user", content: "Hello, world!" } ],
          temperature: 0.7
        }

        @provider.instance_variable_set(:@prompt, @prompt)
        response = @provider.send(:chat_response, mock_response, request_params)

        assert_not_nil response
        # Note: raw_request should be sanitized, but since our test key isn't in the 
        # sanitizers list, it should remain unchanged in this test
        assert_equal request_params, response.raw_request
        assert_equal mock_response, response.raw_response
      end

      test "chat_response sanitizes API keys in raw_request" do
        # Setup sanitizers with our test key
        original_config = ActiveAgent.config
        test_config = { "openai" => { "api_key" => "test-key" } }
        ActiveAgent.instance_variable_set(:@config, test_config)
        ActiveAgent.sanitizers_reset!

        mock_response = {
          "id" => "chatcmpl-456",
          "choices" => [
            {
              "message" => {
                "role" => "assistant",
                "content" => "Response"
              }
            }
          ]
        }

        request_params = {
          model: "gpt-4",
          api_key: "test-key",
          headers: { "Authorization" => "Bearer test-key" },
          messages: [ { role: "user", content: "Message with key: test-key" } ]
        }

        @provider.instance_variable_set(:@prompt, @prompt)
        response = @provider.send(:chat_response, mock_response, request_params)

        # API key should be sanitized in raw_request
        assert_equal "<OPENAI_API_KEY>", response.raw_request[:api_key]
        assert_equal "Bearer <OPENAI_API_KEY>", response.raw_request[:headers]["Authorization"]
        assert_equal "Message with key: <OPENAI_API_KEY>", 
                     response.raw_request[:messages][0][:content]

        # Restore original config
        ActiveAgent.instance_variable_set(:@config, original_config)
        ActiveAgent.sanitizers_reset!
      end

      test "embeddings_response includes raw_request when provided" do
        mock_response = {
          "data" => [
            {
              "embedding" => [ 0.1, 0.2, 0.3 ]
            }
          ]
        }

        request_params = {
          model: "text-embedding-ada-002",
          input: "Hello, world!"
        }

        @provider.instance_variable_set(:@prompt, @prompt)
        response = @provider.send(:embeddings_response, mock_response, request_params)

        assert_not_nil response
        assert_equal request_params, response.raw_request
        assert_equal mock_response, response.raw_response
      end

      test "responses_response includes raw_request when provided" do
        mock_response = {
          "id" => "resp-123",
          "output" => [
            {
              "type" => "message",
              "id" => "msg-123",
              "content" => [ { "text" => "Hello response" } ],
              "role" => "assistant",
              "finish_reason" => "stop"
            }
          ]
        }

        request_params = {
          model: "gpt-4",
          input: { messages: [ { role: "user", content: "Hello" } ] }
        }

        @provider.instance_variable_set(:@prompt, @prompt)
        response = @provider.send(:responses_response, mock_response, request_params)

        assert_not_nil response
        assert_equal request_params, response.raw_request
        assert_equal mock_response, response.raw_response
      end
    end
  end
end
