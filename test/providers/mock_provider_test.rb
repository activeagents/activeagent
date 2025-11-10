# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/mock_provider"

class MockProviderTest < ActiveSupport::TestCase
  setup do
    @provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      messages: [
        { role: "user", content: "Hello world" }
      ]
    )
  end

  test "service_name returns Mock" do
    assert_equal "Mock", @provider.service_name
  end

  test "converts simple message to pig latin" do
    response = @provider.prompt

    assert_not_nil response
    assert response.messages.size >= 1

    message = response.messages.last # Get the assistant's response
    assert_equal "assistant", message.role

    # "Hello world" -> "Ellohay orldway"
    content = message.content
    assert_includes content.downcase, "ellohay"
    assert_includes content.downcase, "orldway"
  end

  test "handles embedding requests" do
    embed_provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      input: "test text"
    )

    response = embed_provider.embed

    assert_not_nil response
    assert_not_nil response.data
    assert_equal 1, response.data.size

    embedding = response.data.first
    assert_equal "embedding", embedding[:object]
    assert_equal 1536, embedding[:embedding].size

    # Verify it's a normalized vector (magnitude should be close to 1)
    magnitude = Math.sqrt(embedding[:embedding].sum { |v| v ** 2 })
    assert_in_delta 1.0, magnitude, 0.001
  end

  test "handles multiple embeddings" do
    embed_provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      input: [ "first text", "second text" ]
    )

    response = embed_provider.embed

    assert_equal 2, response.data.size
    assert_equal 0, response.data[0][:index]
    assert_equal 1, response.data[1][:index]
  end

  test "handles custom embedding dimensions" do
    embed_provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      input: "test",
      dimensions: 768
    )

    response = embed_provider.embed
    assert_equal 768, response.data.first[:embedding].size
  end

  test "pig latin conversion - vowel start" do
    provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      messages: [
        { role: "user", content: "apple" }
      ]
    )

    response = provider.prompt
    content = response.messages.last.content # Get assistant response
    assert_equal "appleway", content
  end

  test "pig latin conversion - consonant start" do
    provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      messages: [
        { role: "user", content: "hello" }
      ]
    )

    response = provider.prompt
    content = response.messages.last.content # Get assistant response
    assert_equal "ellohay", content
  end

  test "pig latin conversion - preserves capitalization" do
    provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      messages: [
        { role: "user", content: "Hello" }
      ]
    )

    response = provider.prompt
    content = response.messages.last.content # Get assistant response
    assert_equal "Ellohay", content
  end

  test "pig latin conversion - handles punctuation" do
    provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      messages: [
        { role: "user", content: "Hello, world!" }
      ]
    )

    response = provider.prompt
    content = response.messages.last.content # Get assistant response
    assert_includes content, "Ellohay"
    assert_includes content, ","
    assert_includes content.downcase, "orldway"
    assert_includes content, "!"
  end

  test "handles array content messages" do
    provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: "Hello" },
            { type: "text", text: "world" }
          ]
        }
      ]
    )

    response = provider.prompt
    content = response.messages.last.content # Get assistant response
    assert_includes content.downcase, "ellohay"
    assert_includes content.downcase, "orldway"
  end

  test "handles streaming" do
    stream_events = []

    provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      messages: [ { role: "user", content: "hello" } ],
      stream: true,
      stream_broadcaster: ->(message, delta, event_type) {
        stream_events << { message: message, delta: delta, type: event_type }
      }
    )

    provider.prompt

    # Should have open, update(s), and close events
    assert stream_events.any? { |e| e[:type] == :open }
    assert stream_events.any? { |e| e[:type] == :update }
    assert stream_events.any? { |e| e[:type] == :close }
  end

  test "returns appropriate response structure" do
    response = @provider.prompt

    assert_not_nil response.raw_request
    assert_not_nil response.raw_response
    assert response.messages.size >= 1

    message = response.messages.last # Get the assistant response
    assert_equal "assistant", message.role
    assert message.content.is_a?(String)
  end
end
