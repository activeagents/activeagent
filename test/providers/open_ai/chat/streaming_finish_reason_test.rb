# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenAI Chat streaming finish reason tests"
  return
end

require_relative "../../../../lib/active_agent/providers/open_ai/chat_provider"

module Providers
  module OpenAI
    module Chat
      class StreamingFinishReasonTest < ActiveSupport::TestCase
        include WebMock::API

        ENDPOINT = "https://api.openai.com/v1/chat/completions"

        def stream_prompt(finish_reason)
          chunks = [
            { choices: [ { index: 0, delta: { role: "assistant", content: "Hi" }, finish_reason: nil } ] },
            { choices: [ { index: 0, delta: {}, finish_reason: finish_reason } ] }
          ]
          body = chunks.map { |chunk|
            "data: #{{ id: "chatcmpl-1", object: "chat.completion.chunk", created: 1_761_502_994, model: "gpt-5.6-terra" }.merge(chunk).to_json}\n\n"
          }.join + "data: [DONE]\n\n"
          stub_request(:post, ENDPOINT).to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body:)

          ActiveAgent::Providers::OpenAI::ChatProvider.new(
            service: "OpenAI",
            api_key: "test-api-key",
            model: "gpt-5.6-terra",
            messages: [ { role: "user", content: "Hello" } ],
            stream: true,
            stream_broadcaster: ->(_message, _delta, _event_type) { }
          ).prompt
        end

        test "a streamed generation reports why it stopped" do
          assert_equal "stop", stream_prompt("stop").finish_reason
        end

        test "a streamed generation cut off at the token limit reports length" do
          assert_equal "length", stream_prompt("length").finish_reason
        end
      end
    end
  end
end
