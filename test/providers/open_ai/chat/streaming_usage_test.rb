# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/active_agent/providers/open_ai/chat_provider"

module Providers
  module OpenAI
    module Chat
      # End-to-end proof that a streamed generation reports its tokens.
      #
      # Chat Completions sends usage on a final chunk that carries an empty
      # choices array, after the content is done, and only when the request
      # asked for it. Recording it has to survive the whole chain — the gem's
      # stream helper, the chunk handler, and the completion deferred until
      # the stream drains — so this drives real response bodies rather than
      # hand-built chunk events.
      class StreamingUsageTest < ActiveSupport::TestCase
        include WebMock::API

        ENDPOINT = "https://api.openai.com/v1/chat/completions"

        USAGE = { prompt_tokens: 14, completion_tokens: 9, total_tokens: 23 }

        # The order a real Chat Completions stream arrives in: content, then
        # the finish_reason chunk, then usage on a chunk with no choices.
        CHUNKS = [
          { choices: [ { index: 0, delta: { role: "assistant", content: "" }, finish_reason: nil } ] },
          { choices: [ { index: 0, delta: { content: "Hi" }, finish_reason: nil } ] },
          { choices: [ { index: 0, delta: { content: " there!" }, finish_reason: nil } ] },
          { choices: [ { index: 0, delta: {}, finish_reason: "stop" } ] },
          { choices: [], usage: USAGE }
        ]

        # Gemini's OpenAI-compatible endpoint ignores the spec and repeats a
        # running usage total on every chunk instead of sending one at the end.
        CUMULATIVE_CHUNKS = CHUNKS[0..3].each_with_index.map { |chunk, index|
          chunk.merge(usage: USAGE.transform_values { |count| ((count * (index + 1)) / 4.0).ceil })
        } + [ CHUNKS.last ]

        def sse_body(chunks)
          chunks.map { |chunk|
            envelope = {
              id:      "chatcmpl-stream-usage",
              object:  "chat.completion.chunk",
              created: 1_761_502_994,
              model:   "gpt-4o-mini"
            }

            "data: #{envelope.merge(chunk).to_json}\n\n"
          }.join + "data: [DONE]\n\n"
        end

        def stub_stream(chunks)
          stub_request(:post, ENDPOINT).to_return(
            status:  200,
            headers: { "Content-Type" => "text/event-stream" },
            body:    sse_body(chunks)
          )
        end

        setup do
          @stream_events = []

          stub_stream(CHUNKS)
        end

        def stream_prompt
          ActiveAgent::Providers::OpenAI::ChatProvider.new(
            service:  "OpenAI",
            api_key:  "test-api-key",
            model:    "gpt-4o-mini",
            messages: [ { role: "user", content: "Hello" } ],
            stream:   true,
            stream_broadcaster: ->(_message, _delta, event_type) { @stream_events << event_type }
          ).prompt
        end

        test "a streamed generation reports the usage from its final chunk" do
          response = stream_prompt

          assert_equal 14, response.usage.input_tokens
          assert_equal 9,  response.usage.output_tokens
          assert_equal 23, response.usage.total_tokens
        end

        test "usage repeated on every chunk counts once, not once per chunk" do
          stub_stream(CUMULATIVE_CHUNKS)

          response = stream_prompt

          assert_equal 14, response.usage.input_tokens
          assert_equal 9,  response.usage.output_tokens
          assert_equal 23, response.usage.total_tokens
        end

        test "the streamed content still arrives alongside the usage" do
          assert_equal "Hi there!", stream_prompt.message.content
        end

        test "the deferred completion still closes the stream exactly once" do
          stream_prompt

          assert_equal 1, @stream_events.count(:close)
          assert_equal :close, @stream_events.last, "the close must come after the last update"
        end

        test "the request opts in to usage reporting" do
          stream_prompt

          assert_requested :post, ENDPOINT, times: 1 do |request|
            JSON.parse(request.body).dig("stream_options", "include_usage") == true
          end
        end
      end
    end
  end
end
