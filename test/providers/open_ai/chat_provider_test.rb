# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenAI Chat provider tests"
  return
end

require_relative "../../../lib/active_agent/providers/open_ai/chat_provider"

module Providers
  module OpenAI
    module Chat
      class ChatProviderTest < ActiveSupport::TestCase
        include WebMock::API

        setup do
          WebMock.enable!
          @client = ::OpenAI::Client.new(base_url: "http://localhost", api_key: "test-key")
        end

        teardown do
          WebMock.disable!
        end

        test "accumulates streaming tool call deltas into message_stack" do
          stub_streaming_response(tool_calls_sse_response)

          stream = @client.chat.completions.stream(
            messages: [ { content: "What's the weather in Boston?", role: :user } ],
            model: "qwen-plus",
            tools: weather_tool
          )

          chat_provider = ActiveAgent::Providers::OpenAI::ChatProvider.new

          stream.each do |event|
            chat_provider.send(:process_stream_chunk, event)
          end

          expected_message = {
            index: 0,
            role: :assistant,
            tool_calls: [
              {
                index: 0,
                id: "call_123",
                function: {
                  name: "get_weather",
                  arguments: '{"city":"Paris","units":"celsius"}'
                },
                type: :function
              }
            ]
          }

          assert_equal(
            [ expected_message ],
            chat_provider.send(:message_stack),
            "message_stack should contain one assistant message with merged tool_calls"
          )
        end

        private

        def stub_streaming_response(response_body, request_options = {})
          default_request = {
            messages: [ { content: "What's the weather in Boston?", role: "user" } ],
            model: "qwen-plus",
            stream: true
          }

          stub_request(:post, "http://localhost/chat/completions")
            .with(body: hash_including(default_request.merge(request_options)))
            .to_return(
              status: 200,
              headers: { "Content-Type" => "text/event-stream" },
              body: response_body
            )
        end

        def tool_calls_sse_response
          <<~SSE
            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"qwen-plus","choices":[{"index":0,"content":null,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}

            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"qwen-plus","choices":[{"index":0,"content":null,"delta":{"tool_calls":[{"index":0,"type":"function","function":{"arguments":"{\\"city\\":"}}]},"finish_reason":null}]}

            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"qwen-plus","choices":[{"index":0,"content":null,"delta":{"tool_calls":[{"index":0,"type":"function","function":{"arguments":"\\"Paris\\","}}]},"finish_reason":null}]}

            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"qwen-plus","choices":[{"index":0,"content":null,"delta":{"tool_calls":[{"index":0,"type":"function","function":{"arguments":"\\"units\\":\\"celsius\\"}"}}]},"finish_reason":null}]}

            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"qwen-plus","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

          SSE
        end

        def weather_tool
          [
            {
              type: :function,
              function: {
                name: "get_weather",
                parameters: {
                  type: "object",
                  properties: {
                    city: { type: "string" },
                    units: { type: "string" }
                  },
                  required: [ "city", "units" ],
                  additionalProperties: false
                },
                strict: true
              }
            }
          ]
        end
      end
    end
  end
end
