# frozen_string_literal: true

require "test_helper"

# Ensure RubyLLM stubs are loaded before the provider
require_relative "ruby_llm_provider_test"

class RubyLLMModelsTest < ActiveSupport::TestCase
  # --- Request ---

  test "Request has model attribute" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(model: "gpt-4o-mini")
    assert_equal "gpt-4o-mini", request.model
  end

  test "Request has messages attribute" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Hello" }]
    )

    assert_equal 1, request.messages.size
    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::User, request.messages.first
  end

  test "Request message= appends to messages" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(model: "gpt-4o-mini")
    request.message = { role: "user", content: "Hello" }

    assert_equal 1, request.messages.size
  end

  test "Request message= initializes messages when nil" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(model: "gpt-4o-mini")
    # messages should be nil initially since no messages were passed
    request.message = { role: "user", content: "First" }
    request.message = { role: "user", content: "Second" }

    assert_equal 2, request.messages.size
  end

  test "Request has instructions attribute" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(
      model: "gpt-4o-mini",
      instructions: "Be helpful."
    )

    assert_equal "Be helpful.", request.instructions
  end

  test "Request has tools attribute" do
    tools = [{ name: "search", description: "Search things" }]
    request = ActiveAgent::Providers::RubyLLM::Request.new(
      model: "gpt-4o-mini",
      tools: tools
    )

    assert_equal tools, request.tools
  end

  test "Request has tool_choice attribute" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(
      model: "gpt-4o-mini",
      tool_choice: "required"
    )

    assert_equal "required", request.tool_choice
  end

  test "Request has temperature attribute" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(
      model: "gpt-4o-mini",
      temperature: 0.7
    )

    assert_in_delta 0.7, request.temperature
  end

  test "Request has max_tokens attribute" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(
      model: "gpt-4o-mini",
      max_tokens: 1024
    )

    assert_equal 1024, request.max_tokens
  end

  test "Request stream defaults to false" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(model: "gpt-4o-mini")
    assert_equal false, request.stream
  end

  test "Request has response_format attribute" do
    request = ActiveAgent::Providers::RubyLLM::Request.new(
      model: "gpt-4o-mini",
      response_format: { type: "json_object" }
    )

    assert_equal({ type: "json_object" }, request.response_format)
  end

  # --- Options ---

  test "Options initializes with model" do
    options = ActiveAgent::Providers::RubyLLM::Options.new(model: "gpt-4o-mini")
    assert_equal "gpt-4o-mini", options.model
  end

  test "Options initializes with temperature" do
    options = ActiveAgent::Providers::RubyLLM::Options.new(
      model: "gpt-4o-mini",
      temperature: 0.5
    )

    assert_in_delta 0.5, options.temperature
  end

  test "Options initializes with max_tokens" do
    options = ActiveAgent::Providers::RubyLLM::Options.new(
      model: "gpt-4o-mini",
      max_tokens: 2048
    )

    assert_equal 2048, options.max_tokens
  end

  test "Options extra_headers returns empty hash" do
    options = ActiveAgent::Providers::RubyLLM::Options.new(model: "gpt-4o-mini")
    assert_equal({}, options.extra_headers)
  end

  test "Options handles string keys via deep_symbolize_keys" do
    options = ActiveAgent::Providers::RubyLLM::Options.new("model" => "gpt-4o-mini")
    assert_equal "gpt-4o-mini", options.model
  end

  # --- EmbeddingRequest ---

  test "EmbeddingRequest has model attribute" do
    request = ActiveAgent::Providers::RubyLLM::EmbeddingRequest.new(
      model: "text-embedding-3-small"
    )

    assert_equal "text-embedding-3-small", request.model
  end

  test "EmbeddingRequest has input attribute" do
    request = ActiveAgent::Providers::RubyLLM::EmbeddingRequest.new(
      model: "text-embedding-3-small",
      input: "Hello world"
    )

    assert_equal "Hello world", request.input
  end

  test "EmbeddingRequest has dimensions attribute" do
    request = ActiveAgent::Providers::RubyLLM::EmbeddingRequest.new(
      model: "text-embedding-3-small",
      input: "Hello",
      dimensions: 768
    )

    assert_equal 768, request.dimensions
  end

  test "EmbeddingRequest accepts array input" do
    request = ActiveAgent::Providers::RubyLLM::EmbeddingRequest.new(
      model: "text-embedding-3-small",
      input: ["Hello", "World"]
    )

    assert_equal ["Hello", "World"], request.input
  end
end
