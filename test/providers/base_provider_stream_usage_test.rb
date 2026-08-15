# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/mock_provider"

# Streamed token usage: a streaming request has no response body to read
# usage from — the provider emits it on a final chunk, after the content is
# done. Without recording that chunk and deferring the end-of-generation work
# until the stream drains, every streamed generation reports zero tokens (and
# so zero cost, and no context-pressure estimate downstream).
class BaseProviderStreamUsageTest < ActiveSupport::TestCase
  # Stands in for a provider whose stream ends with a usage-bearing chunk.
  class StreamingMockProvider < ActiveAgent::Providers::MockProvider
    def self.name = "ActiveAgent::Providers::MockProvider"

    class_attribute :usage_payload, default: nil

    # Mimics the real shape: content arrives first and marks the generation
    # complete, then a final chunk carries the usage.
    def api_prompt_execute(parameters)
      return super unless parameters[:stream]

      message_stack.push({ role: "assistant", content: "ok" })
      self.stream_completion_pending = true
      record_stream_usage(self.class.usage_payload)
      stream_finished!
      nil
    end
  end

  def build(usage:)
    StreamingMockProvider.usage_payload = usage
    StreamingMockProvider.new(messages: [ { role: "user", content: "go" } ], stream: true)
  end

  test "records usage delivered on a final streaming chunk" do
    response = build(usage: { "prompt_tokens" => 14, "completion_tokens" => 4, "total_tokens" => 18 }).prompt

    assert_equal 14, response.usage.input_tokens
    assert_equal 4, response.usage.output_tokens
  end

  test "converts a provider model object rather than dropping it" do
    # The stainless gems hand back model objects, not hashes; from_provider_usage
    # only reads hashes, so an unconverted object is silently ignored.
    object_usage = Struct.new(:to_h).new(
      { "prompt_tokens" => 30, "completion_tokens" => 9, "total_tokens" => 39 }
    )

    response = build(usage: object_usage).prompt

    assert_equal 30, response.usage.input_tokens
    assert_equal 9, response.usage.output_tokens
  end

  test "ignores the empty usage sent on ordinary content chunks" do
    provider = build(usage: nil)
    provider.prompt

    assert_empty provider.usage_stack

    provider = build(usage: { "prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0 })
    provider.prompt

    assert_empty provider.usage_stack, "an all-zero payload should not enter the stack"
  end

  test "a repeated cumulative usage replaces the turn's entry instead of stacking" do
    # Gemini's OpenAI-compatible endpoint repeats a running total on every
    # chunk rather than sending one usage at the end of the stream.
    provider = build(usage: nil)
    [ 6, 12, 18 ].each do |total|
      provider.send(:record_stream_usage,
                    { "prompt_tokens" => total - 2, "completion_tokens" => 2, "total_tokens" => total })
    end

    assert_equal 1, provider.usage_stack.size
    assert_equal 16, provider.usage_stack.first.input_tokens, "the last running total wins"
  end

  test "each turn of a generation records its own usage" do
    # Tool calling re-enters resolve_prompt per turn, and each turn streams a
    # usage of its own — those accumulate rather than replacing one another.
    provider = build(usage: { "prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6 })

    provider.prompt
    response = provider.prompt

    assert_equal 2, provider.usage_stack.size
    assert_equal 10, response.usage.input_tokens
  end

  # Chat Completions' own opt-in is asserted against a real serialized request
  # in Providers::OpenAI::Chat::StreamingUsageTest.
  test "the default provider asks for no extra streaming parameters" do
    assert_empty build(usage: nil).send(:api_stream_usage_parameters)
  end

  test "a deferred completion runs process_prompt_finished exactly once" do
    provider = build(usage: { "prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6 })

    calls = 0
    provider.define_singleton_method(:process_prompt_finished) do |*args|
      calls += 1
      super(*args)
    end

    provider.prompt

    assert_equal 1, calls, "resolve_prompt must not re-finish a stream that already completed"
  end
end
