# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic_provider"

module Providers
  module Anthropic
    # `response_format: { type: "json_object" }` end to end. Everything below
    # the HTTP call is real: request serialization, the gem's response and
    # stream parsing, and the provider's retry. Each test asserts on the
    # request bodies the Messages API receives.
    #
    # A model that accepts a prefill gets one while thinking is off: the request
    # ends on an assistant turn holding the lead-in, which the answer continues.
    # Every other request ends on the user's turn, and the JSON is read from the
    # answer as written.
    class JsonObjectEmulationTest < ActiveSupport::TestCase
      include WebMock::API

      ENDPOINT = "https://api.anthropic.com/v1/messages"
      LEAD_IN  = ActiveAgent::Providers::AnthropicProvider::JSON_RESPONSE_FORMAT_LEAD_IN
      QUESTION = "Return a JSON object with the three primary colors in an array named 'colors'."
      COLORS   = { colors: [ "red", "yellow", "blue" ] }.freeze

      USER_TURN    = { "role" => "user", "content" => QUESTION }.freeze
      LEAD_IN_TURN = { "role" => "assistant", "content" => LEAD_IN }.freeze

      ANSWER        = '{"colors": ["red", "yellow", "blue"]}'
      FENCED_ANSWER = "```json\n#{ANSWER}\n```"
      UNPARSEABLE   = "Red, yellow, and blue."

      # The answer to a prefilled request: it continues the object the lead-in
      # opened.
      CONTINUATION = '"colors": ["red", "yellow", "blue"]}'

      # A model that accepts a prefill, and one that refuses it.
      LEGACY_MODEL  = "claude-haiku-4-5"
      CURRENT_MODEL = "claude-sonnet-4-6"

      # Ids of the models that accept a prefill: each family in its Anthropic
      # alias, dated snapshot, Vertex AI and Amazon Bedrock forms.
      PREFILL_MODEL_IDS = %w[
        claude-haiku-4-5 claude-haiku-4-5-20251001 claude-haiku-4-5@20251001 global.anthropic.claude-haiku-4-5-20251001-v1:0
        claude-sonnet-4-5 claude-sonnet-4-5-20250929 claude-sonnet-4-5@20250929 us.anthropic.claude-sonnet-4-5-20250929-v1:0
        claude-opus-4-5 claude-opus-4-5-20251101 claude-opus-4-5@20251101 anthropic.claude-opus-4-5-20251101-v1:0
        claude-opus-4-1 claude-opus-4-1-20250805 claude-opus-4-1@20250805 us.anthropic.claude-opus-4-1-20250805-v1:0
        claude-opus-4-0 claude-opus-4-20250514 claude-opus-4@20250514 anthropic.claude-opus-4-20250514-v1:0
        claude-sonnet-4-0 claude-sonnet-4-20250514 claude-sonnet-4@20250514 eu.anthropic.claude-sonnet-4-20250514-v1:0
        claude-3-7-sonnet-latest claude-3-7-sonnet-20250219 claude-3-7-sonnet@20250219 us.anthropic.claude-3-7-sonnet-20250219-v1:0
        claude-3-5-sonnet-latest claude-3-5-sonnet-20241022 claude-3-5-sonnet-v2@20241022 anthropic.claude-3-5-sonnet-20241022-v2:0
        claude-3-5-sonnet-20240620 claude-3-5-sonnet@20240620 anthropic.claude-3-5-sonnet-20240620-v1:0
        claude-3-5-haiku-latest claude-3-5-haiku-20241022 claude-3-5-haiku@20241022 anthropic.claude-3-5-haiku-20241022-v1:0
        claude-3-opus-latest claude-3-opus-20240229 claude-3-opus@20240229 anthropic.claude-3-opus-20240229-v1:0
        claude-3-sonnet-20240229 claude-3-sonnet@20240229 anthropic.claude-3-sonnet-20240229-v1:0
        claude-3-haiku-20240307 claude-3-haiku@20240307 apac.anthropic.claude-3-haiku-20240307-v1:0
      ].freeze

      # Ids that get no prefill: every current model, which refuses one with or
      # without thinking (Vertex AI uses the same bare ids), current models on
      # Amazon Bedrock, an id the provider does not know, and no model at all.
      NO_PREFILL_MODEL_IDS = [
        "claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4-7", "claude-opus-4-8",
        "claude-sonnet-5", "claude-opus-5", "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1",
        "eu.anthropic.claude-sonnet-5-v1:0", "anthropic.claude-opus-5",
        "deepseek-flash",
        nil
      ].freeze

      # The two ways to turn thinking on, each on a model that accepts it:
      # Haiku 4.5 takes only a manual budget, Sonnet 4.6 takes adaptive.
      THINKING_MODES = {
        "manual"   => { model: LEGACY_MODEL,  thinking: { type: "enabled", budget_tokens: 2048 } },
        "adaptive" => { model: CURRENT_MODEL, thinking: { type: "adaptive" } }
      }.freeze

      # The fields of a Messages API response that every stubbed answer shares.
      ENVELOPE = {
        id:            "msg_json_object",
        type:          "message",
        role:          "assistant",
        model:         LEGACY_MODEL,
        stop_sequence: nil,
        usage:         { input_tokens: 24, output_tokens: 12 }
      }.freeze

      def json_object_provider(model: LEGACY_MODEL, **options)
        ActiveAgent::Providers::AnthropicProvider.new(
          service:         "Anthropic",
          api_key:         "test-api-key",
          model:           model,
          messages:        [ { role: "user", content: QUESTION } ],
          response_format: { type: "json_object" },
          **options
        )
      end

      def streaming_provider(**options)
        json_object_provider(stream: true, stream_broadcaster: ->(_message, _delta, _event_type) { }, **options)
      end

      # Whether a json_object request for model, with options, is prefilled.
      def prefill?(model, **options)
        provider = json_object_provider(model: model, **options)
        provider.request = provider.class.prompt_request_type.cast(
          { model: model, messages: [ { role: "user", content: QUESTION } ], response_format: { type: "json_object" }, **options }.compact
        )

        provider.send(:json_object_prefill?)
      end

      # Answers successive requests with bodies, in order, and returns the list
      # the parsed request bodies are collected into. The last body answers
      # every request after the others run out.
      def stub_responses(*bodies, content_type: "application/json")
        requests = []
        queue    = bodies.dup

        stub_request(:post, ENDPOINT).to_return do |request|
          requests << JSON.parse(request.body)
          { status: 200, headers: { "Content-Type" => content_type }, body: queue.size > 1 ? queue.shift : queue.first }
        end

        requests
      end

      def stub_streams(*bodies)
        stub_responses(*bodies, content_type: "text/event-stream")
      end

      def response_body(*content)
        ENVELOPE.merge(content: content, stop_reason: "end_turn").to_json
      end

      def thinking
        { type: "thinking", thinking: "The user wants the primary colors.", signature: "c2lnbmF0dXJl" }
      end

      def text(value)
        { type: "text", text: value }
      end

      # The server-sent events of a message that thinks first and then answers
      # with `answer`, split across two text deltas.
      def stream_body(answer)
        half = answer.length / 2

        [
          { type: "message_start", message: ENVELOPE.merge(content: [], stop_reason: nil) },
          { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "", signature: "" } },
          { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "The user wants the primary colors." } },
          { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "c2lnbmF0dXJl" } },
          { type: "content_block_stop",  index: 0 },
          { type: "content_block_start", index: 1, content_block: { type: "text", text: "" } },
          { type: "content_block_delta", index: 1, delta: { type: "text_delta", text: answer[0...half] } },
          { type: "content_block_delta", index: 1, delta: { type: "text_delta", text: answer[half..] } },
          { type: "content_block_stop",  index: 1 },
          { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: nil }, usage: { output_tokens: 12 } },
          { type: "message_stop" }
        ].map { |event| "event: #{event[:type]}\ndata: #{event.to_json}\n\n" }.join
      end

      ################################################################################
      # Which requests are prefilled
      ################################################################################

      PREFILL_MODEL_IDS.each do |model|
        test "#{model}: prefilled" do
          assert prefill?(model)
        end
      end

      NO_PREFILL_MODEL_IDS.each do |model|
        test "#{model || 'no model'}: not prefilled" do
          assert_not prefill?(model)
        end
      end

      test "a model that accepts a prefill gets none with thinking on" do
        assert_not prefill?(LEGACY_MODEL, thinking: { type: "enabled", budget_tokens: 2048 })
      end

      test "disabled thinking leaves the prefill in place" do
        assert prefill?(LEGACY_MODEL, thinking: { type: "disabled" })
      end

      ################################################################################
      # Without the lead-in
      ################################################################################

      test "current model: the request ends on the user's turn and its answer is parsed" do
        requests = stub_responses(response_body(text(ANSWER)))

        response = json_object_provider(model: CURRENT_MODEL).prompt

        assert_equal [ USER_TURN ], requests.sole["messages"]
        assert_equal COLORS, response.message.parsed_json
      end

      test "current model: an unparseable answer is retried without it in the conversation" do
        requests = stub_responses(response_body(text(UNPARSEABLE)), response_body(text(ANSWER)))

        response = json_object_provider(model: CURRENT_MODEL).prompt

        assert_equal [ [ USER_TURN ] ] * 2, requests.map { |request| request["messages"] }, "the retry must not end on the unparseable answer"
        assert_equal COLORS, response.message.parsed_json
        assert_not_includes response.messages.map(&:content), UNPARSEABLE
      end

      THINKING_MODES.each do |mode, config|
        test "#{mode} thinking: the request ends on the user's turn, not a prefill" do
          requests = stub_responses(response_body(thinking, text(ANSWER)))

          json_object_provider(**config).prompt

          assert_equal [ USER_TURN ], requests.sole["messages"]
          assert_equal config[:thinking].deep_stringify_keys, requests.sole["thinking"]
        end

        test "#{mode} thinking: the answer's JSON is parsed" do
          stub_responses(response_body(thinking, text(ANSWER)))

          assert_equal COLORS, json_object_provider(**config).prompt.message.parsed_json
        end
      end

      test "thinking: an answer inside a Markdown code fence is parsed" do
        stub_responses(response_body(thinking, text(FENCED_ANSWER)))

        response = json_object_provider(**THINKING_MODES["adaptive"]).prompt

        assert_equal COLORS, response.message.parsed_json
      end

      test "thinking: an unparseable answer is retried without it in the conversation" do
        requests = stub_responses(
          response_body(thinking, text(UNPARSEABLE)),
          response_body(thinking, text(ANSWER))
        )

        response = json_object_provider(**THINKING_MODES["adaptive"]).prompt

        assert_equal [ [ USER_TURN ] ] * 2, requests.map { |request| request["messages"] }, "the retry must not end on the unparseable answer"
        assert_equal COLORS, response.message.parsed_json
        assert_not_includes response.messages.map(&:content), UNPARSEABLE
      end

      test "thinking: retries run out with no request ending on an assistant turn" do
        requests = stub_responses(response_body(thinking, text(UNPARSEABLE)))

        response = json_object_provider(**THINKING_MODES["manual"]).prompt

        assert_equal 1 + ::Anthropic::Client::DEFAULT_MAX_RETRIES, requests.size
        assert(requests.all? { |request| request["messages"] == [ USER_TURN ] }, "no request may end on an assistant turn")
        assert_nil response.message.parsed_json
      end

      test "thinking: a streamed request ends on the user's turn and its answer is parsed" do
        requests = stub_streams(stream_body(FENCED_ANSWER))

        response = streaming_provider(**THINKING_MODES["adaptive"]).prompt

        assert_equal [ USER_TURN ], requests.sole["messages"]
        assert_equal COLORS, response.message.parsed_json
      end

      test "thinking: an unparseable streamed answer is retried without it in the conversation" do
        requests = stub_streams(stream_body(UNPARSEABLE), stream_body(ANSWER))

        response = streaming_provider(**THINKING_MODES["adaptive"]).prompt

        assert_equal [ [ USER_TURN ] ] * 2, requests.map { |request| request["messages"] }, "the retry must not end on the unparseable answer"
        assert_equal COLORS, response.message.parsed_json
        assert_not_includes response.messages.map(&:content), UNPARSEABLE
      end

      ################################################################################
      # With the lead-in
      ################################################################################

      {
        "no thinking"       => {},
        "disabled thinking" => { thinking: { type: "disabled" } }
      }.each do |mode, config|
        test "legacy model, #{mode}: the request ends on the lead-in" do
          requests = stub_responses(response_body(text(CONTINUATION)))

          json_object_provider(**config).prompt

          assert_equal [ USER_TURN, LEAD_IN_TURN ], requests.sole["messages"]
        end

        test "legacy model, #{mode}: the continuation gets its brace back and is parsed" do
          stub_responses(response_body(text(CONTINUATION)))

          response = json_object_provider(**config).prompt

          assert_equal COLORS, response.message.parsed_json
          assert_not_includes response.messages.map(&:content), LEAD_IN
        end
      end

      test "legacy model: the retry ends on the lead-in again" do
        requests = stub_responses(response_body(text(UNPARSEABLE)), response_body(text(CONTINUATION)))

        response = json_object_provider.prompt

        assert_equal 2, requests.size
        assert_equal LEAD_IN_TURN, requests.last["messages"].last
        assert_equal COLORS, response.message.parsed_json
      end
    end
  end
end
