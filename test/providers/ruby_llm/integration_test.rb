# frozen_string_literal: true

# Integration test for the RubyLLM provider against real OpenAI API.
#
# Run with:
#   BUNDLE_GEMFILE=gemfiles/rails8.gemfile mise exec ruby@3.3.10 -- bundle exec ruby -Itest test/providers/ruby_llm/integration_test.rb
#
# Requires: OPENAI_API_KEY env var set.

unless ENV["OPENAI_API_KEY"]
  # When run via rake test without the key, define a no-op test class.
  require "test_helper"

  class RubyLLMIntegrationTest < ActiveSupport::TestCase
    test "skipped - OPENAI_API_KEY not set" do
      skip "Set OPENAI_API_KEY to run RubyLLM integration tests"
    end
  end

  return
end

require "test_helper"
require "ruby_llm"

# Configure RubyLLM with real API key
RubyLLM.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
end

# Allow real HTTP connections for integration tests
if defined?(VCR)
  VCR.configure do |config|
    config.allow_http_connections_when_no_cassette = true
  end
end

if defined?(WebMock)
  WebMock.allow_net_connect!
end

require "active_agent/providers/ruby_llm_provider"

class RubyLLMIntegrationTest < ActiveSupport::TestCase
  test "basic non-streaming prompt" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Reply with exactly two words: hello world" }]
    )

    response = provider.prompt

    assert_not_nil response
    assert response.messages.any?

    content = response.messages.last.content
    assert content.present?, "Expected non-empty content"
    assert_match(/hello world/i, content)

    assert_not_nil response.usage
    assert response.usage.input_tokens.to_i > 0
    assert response.usage.output_tokens.to_i > 0
  end

  test "streaming prompt" do
    events = []

    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Reply with exactly two words: streaming works" }],
      stream: true,
      stream_broadcaster: ->(message, delta, event_type) {
        events << { type: event_type, delta: delta }
      }
    )

    provider.prompt

    assert events.any? { |e| e[:type] == :open }, "Missing open event"
    assert events.any? { |e| e[:type] == :update }, "Missing update events"
    assert events.any? { |e| e[:type] == :close }, "Missing close event"

    deltas = events.select { |e| e[:type] == :update && e[:delta] }.map { |e| e[:delta] }
    full_text = deltas.join
    assert full_text.present?, "Streamed content should not be empty"
  end

  test "tool calling" do
    tool_calls_received = []

    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "What is the weather in Boston? Use the get_weather tool." }],
      tools: [
        {
          type: "function",
          function: {
            name: "get_weather",
            description: "Get the current weather for a given location",
            parameters: {
              type: "object",
              properties: {
                location: { type: "string", description: "City name" }
              },
              required: ["location"]
            }
          }
        }
      ],
      tools_function: ->(name, **kwargs) {
        tool_calls_received << { name: name, kwargs: kwargs }
        { temperature: 72, condition: "sunny", unit: "fahrenheit" }
      }
    )

    response = provider.prompt

    assert tool_calls_received.any?, "Tool should have been called"
    assert_equal "get_weather", tool_calls_received.first[:name]

    content = response.messages.last.content
    assert content.present?, "Final response should not be empty"
  end

  test "embedding" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "text-embedding-3-small",
      input: "The quick brown fox"
    )

    response = provider.embed

    assert_not_nil response
    assert response.data.any?

    embedding = response.data.first[:embedding]
    assert_kind_of Array, embedding
    assert_equal 1536, embedding.size
  end

  test "system instructions" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      instructions: "You must always respond with exactly the word 'PINEAPPLE' and nothing else.",
      messages: [{ role: "user", content: "Say something" }]
    )

    response = provider.prompt
    content = response.messages.last.content

    assert content.present?
    assert_match(/pineapple/i, content)
  end
end
