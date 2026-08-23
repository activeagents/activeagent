# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/mock_provider"

# Time to first token: no provider wire format used here reports it, so the
# base provider observes it — the moment the first streamed chunk of any kind
# arrives, and the moment the first non-empty content delta does. A
# non-streamed request has no observable first token, so it reports nothing
# rather than letting total latency stand in and poison the percentiles.
class BaseProviderStreamTimingTest < ActiveSupport::TestCase
  def build(stream: true, message: "hello there")
    kwargs = { messages: [ { role: "user", content: message } ] }
    kwargs.merge!(stream: true, stream_broadcaster: ->(_message, _delta, _type) { }) if stream

    ActiveAgent::Providers::MockProvider.new(**kwargs)
  end

  # Replaces the monotonic clock with a script, one reading per tick:
  # request start, then first chunk, then first token.
  def script_clock(provider, ticks)
    remaining = ticks.dup
    provider.define_singleton_method(:monotonic_time) { remaining.shift || ticks.last }
  end

  test "a streamed generation reports first-chunk and first-token latency" do
    provider = build
    response = provider.prompt

    refute_nil response.time_to_first_chunk_ms
    refute_nil response.ttft_ms
    assert_operator response.time_to_first_chunk_ms, :<=, response.ttft_ms,
                    "a handshake chunk precedes the first text delta"
  end

  test "handshake chunks are the first chunk but never the first token" do
    # The mock streams the Anthropic shape: message_start and an empty
    # content_block_start arrive before any text delta. The clock is read
    # exactly three times — request start, first chunk, first token — so the
    # gap between the readings is the reported latency.
    provider = build
    script_clock(provider, [ 5.0, 5.05, 5.2 ])

    response = provider.prompt

    assert_equal 50.0, response.time_to_first_chunk_ms
    assert_equal 200.0, response.ttft_ms
  end

  test "a non-streamed generation reports no stream latency" do
    response = build(stream: false).prompt

    assert_nil response.ttft_ms
    assert_nil response.time_to_first_chunk_ms
    assert_equal [ {} ], response.timings, "the call still gets a (empty) timing entry"
  end

  test "each turn times itself and the first turn's latency is the generation's" do
    # Tool calling re-enters resolve_prompt per turn; like usage, each turn
    # gets its own entry. The generation's TTFT is the first turn's — a
    # later turn's clock starts at its own request, not the user's.
    provider = build
    script_clock(provider, [ 0.0, 0.1, 0.3, 1.0, 1.5, 1.9 ])

    provider.prompt
    response = provider.prompt

    assert_equal 2, response.timings.size
    assert_equal 300.0, response.ttft_ms
    assert_equal 100.0, response.time_to_first_chunk_ms
  end

  test "an empty delta is not a token but a whitespace one is" do
    provider = build
    provider.send(:begin_stream_timing)

    provider.send(:record_stream_first_token, nil)
    provider.send(:record_stream_first_token, "")
    assert_nil provider.stream_turn_timing[:first_token_ms]

    provider.send(:record_stream_first_token, " ")
    refute_nil provider.stream_turn_timing[:first_token_ms]
  end

  test "the notification payloads carry the stream latency" do
    payloads = Hash.new { |hash, key| hash[key] = [] }
    callback = ->(name, _start, _finish, _id, payload) { payloads[name] << payload }

    response = nil
    ActiveSupport::Notifications.subscribed(callback, /\Aprompt(\.provider)?\.active_agent\z/) do
      response = build.prompt
    end

    top_level = payloads["prompt.active_agent"].last
    assert_equal response.ttft_ms, top_level[:ttft_ms]
    assert_equal response.time_to_first_chunk_ms, top_level[:time_to_first_chunk_ms]

    per_call = payloads["prompt.provider.active_agent"].last
    refute_nil per_call[:ttft_ms]
    refute_nil per_call[:time_to_first_chunk_ms]
  end

  test "a non-streamed request's payload omits the latency keys entirely" do
    payloads = []
    callback = ->(_name, _start, _finish, _id, payload) { payloads << payload }

    ActiveSupport::Notifications.subscribed(callback, "prompt.active_agent") do
      build(stream: false).prompt
    end

    refute payloads.last.key?(:ttft_ms), "nil must not masquerade as a measurement"
    refute payloads.last.key?(:time_to_first_chunk_ms)
  end

  test "the response surfaces the first turn that produced text" do
    # A tool-call-only first turn streams chunks but never a text delta; the
    # generation's TTFT comes from the first turn that has one.
    response = ActiveAgent::Providers::Common::PromptResponse.new(
      timings: [ { first_chunk_ms: 80.0 }, { first_chunk_ms: 90.0, first_token_ms: 210.0 } ]
    )

    assert_equal 210.0, response.ttft_ms
    assert_equal 80.0, response.time_to_first_chunk_ms
  end
end
