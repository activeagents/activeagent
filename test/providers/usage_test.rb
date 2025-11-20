# frozen_string_literal: true

require "test_helper"

# Smoke tests to verify usage payload instrumentation works across all providers
class UsageTest < ActiveSupport::TestCase
  # Anthropic Provider Tests

  class AnthropicTestAgent < ActiveAgent::Base
    generate_with :anthropic, model: "claude-3-5-haiku-20241022"

    def chat
      prompt(message: params[:message])
    end
  end

  test "Anthropic provider includes usage in instrumentation payload" do
    VCR.use_cassette("usage/anthropic_prompt") do
      received_payload = nil

      subscription = ActiveSupport::Notifications.subscribe("prompt.provider.active_agent") do |event|
        received_payload = event.payload if event.payload[:provider] == "Anthropic"
      end

      response = AnthropicTestAgent.with(message: "Say hello").chat.generate_now

      assert response.success?
      assert_not_nil received_payload, "Should receive provider-level event"
      assert_not_nil received_payload[:usage], "Provider-level event should have usage"
      assert_kind_of Integer, received_payload[:usage][:input_tokens]
      assert_kind_of Integer, received_payload[:usage][:output_tokens]
      assert_kind_of Integer, received_payload[:usage][:total_tokens]
      assert received_payload[:usage][:input_tokens] > 0
      assert received_payload[:usage][:output_tokens] > 0
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end

  # OpenAI Chat Provider Tests

  class OpenAIChatTestAgent < ActiveAgent::Base
    generate_with :openai, model: "gpt-4o-mini"

    def chat
      prompt(message: params[:message])
    end
  end

  test "OpenAI Chat provider includes usage in instrumentation payload" do
    VCR.use_cassette("usage/openai_chat_prompt") do
      received_payload = nil

      subscription = ActiveSupport::Notifications.subscribe("prompt.provider.active_agent") do |event|
        received_payload = event.payload if event.payload[:provider] == "OpenAI"
      end

      response = OpenAIChatTestAgent.with(message: "Say hello").chat.generate_now

      assert response.success?
      assert_not_nil received_payload, "Should receive provider-level event"
      assert_not_nil received_payload[:usage], "Provider-level event should have usage"
      assert_kind_of Integer, received_payload[:usage][:input_tokens]
      assert_kind_of Integer, received_payload[:usage][:output_tokens]
      assert_kind_of Integer, received_payload[:usage][:total_tokens]
      assert received_payload[:usage][:input_tokens] > 0
      assert received_payload[:usage][:output_tokens] > 0
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end

  # OpenAI Responses Provider Tests

  class OpenAIResponsesTestAgent < ActiveAgent::Base
    generate_with :openai, model: "gpt-4o-mini", api_version: :responses

    def chat
      prompt(message: params[:message])
    end
  end

  test "OpenAI Responses provider includes usage in instrumentation payload" do
    VCR.use_cassette("usage/openai_responses_prompt") do
      received_payload = nil

      subscription = ActiveSupport::Notifications.subscribe("prompt.provider.active_agent") do |event|
        received_payload = event.payload if event.payload[:provider] == "OpenAI"
      end

      response = OpenAIResponsesTestAgent.with(message: "Say hello").chat.generate_now

      assert response.success?
      assert_not_nil received_payload, "Should receive provider-level event"
      assert_not_nil received_payload[:usage], "Provider-level event should have usage"
      assert_kind_of Integer, received_payload[:usage][:input_tokens]
      assert_kind_of Integer, received_payload[:usage][:output_tokens]
      assert_kind_of Integer, received_payload[:usage][:total_tokens]
      assert received_payload[:usage][:input_tokens] > 0
      assert received_payload[:usage][:output_tokens] > 0
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end

  # OpenAI Embedding Provider Tests

  class OpenAIEmbeddingTestAgent < ActiveAgent::Base
    embed_with :openai, model: "text-embedding-3-small"
  end

  test "OpenAI Embedding provider includes usage in instrumentation payload" do
    VCR.use_cassette("usage/openai_embedding") do
      received_payload = nil

      subscription = ActiveSupport::Notifications.subscribe("embed.provider.active_agent") do |event|
        received_payload = event.payload if event.payload[:provider] == "OpenAI"
      end

      response = OpenAIEmbeddingTestAgent.embed(input: "Hello world").generate_now

      assert response.success?
      assert_not_nil received_payload, "Should receive provider-level event"
      assert_not_nil received_payload[:usage], "Provider-level event should have usage"
      assert_kind_of Integer, received_payload[:usage][:input_tokens]
      assert_kind_of Integer, received_payload[:usage][:total_tokens]
      assert received_payload[:usage][:input_tokens] > 0
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end

  # Ollama Provider Tests

  class OllamaTestAgent < ActiveAgent::Base
    generate_with :ollama, model: "deepseek-r1:latest"

    def chat
      prompt(message: params[:message])
    end
  end

  test "Ollama Chat provider includes usage in instrumentation payload" do
    VCR.use_cassette("usage/ollama_chat_prompt") do
      received_payload = nil

      subscription = ActiveSupport::Notifications.subscribe("prompt.provider.active_agent") do |event|
        received_payload = event.payload if event.payload[:provider] == "Ollama"
      end

      response = OllamaTestAgent.with(message: "Say hello").chat.generate_now

      assert response.success?
      assert_not_nil received_payload, "Should receive provider-level event"
      assert_not_nil received_payload[:usage], "Provider-level event should have usage"
      assert_kind_of Integer, received_payload[:usage][:input_tokens]
      assert_kind_of Integer, received_payload[:usage][:output_tokens]
      assert_kind_of Integer, received_payload[:usage][:total_tokens]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end

  class OllamaEmbeddingTestAgent < ActiveAgent::Base
    embed_with :ollama, model: "all-minilm"
  end

  test "Ollama Embedding provider includes usage in instrumentation payload" do
    VCR.use_cassette("usage/ollama_embedding") do
      received_payload = nil

      subscription = ActiveSupport::Notifications.subscribe("embed.provider.active_agent") do |event|
        received_payload = event.payload if event.payload[:provider] == "Ollama"
      end

      response = OllamaEmbeddingTestAgent.embed(input: "Hello world").generate_now

      assert response.success?
      assert_not_nil received_payload, "Should receive provider-level event"
      # Note: Ollama may or may not include usage data for embeddings
      if received_payload[:usage]
        assert_kind_of Integer, received_payload[:usage][:input_tokens]
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end

  # OpenRouter Provider Tests

  class OpenRouterTestAgent < ActiveAgent::Base
    generate_with :open_router, model: "anthropic/claude-3.5-haiku"

    def chat
      prompt(message: params[:message])
    end
  end

  test "OpenRouter Chat provider includes usage in instrumentation payload" do
    VCR.use_cassette("usage/openrouter_chat_prompt") do
      received_payload = nil

      subscription = ActiveSupport::Notifications.subscribe("prompt.provider.active_agent") do |event|
        received_payload = event.payload if event.payload[:provider] == "OpenRouter"
      end

      response = OpenRouterTestAgent.with(message: "Say hello").chat.generate_now

      assert response.success?
      assert_not_nil received_payload, "Should receive provider-level event"
      assert_not_nil received_payload[:usage], "Provider-level event should have usage"
      assert_kind_of Integer, received_payload[:usage][:input_tokens]
      assert_kind_of Integer, received_payload[:usage][:output_tokens]
      assert_kind_of Integer, received_payload[:usage][:total_tokens]
      assert received_payload[:usage][:input_tokens] > 0
      assert received_payload[:usage][:output_tokens] > 0
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end
end
