# frozen_string_literal: true

require "test_helper"

# Ensure RubyLLM stubs are loaded before the provider
require_relative "ruby_llm_provider_test"

class RubyLLMTypesTest < ActiveSupport::TestCase
  # --- RequestType ---

  test "RequestType casts hash to Request" do
    type = ActiveAgent::Providers::RubyLLM::RequestType.new
    request = type.cast({
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Hello" }]
    })

    assert_kind_of ActiveAgent::Providers::RubyLLM::Request, request
    assert_equal "gpt-4o-mini", request.model
  end

  test "RequestType passes through Request instances" do
    type = ActiveAgent::Providers::RubyLLM::RequestType.new
    original = ActiveAgent::Providers::RubyLLM::Request.new(
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Hello" }]
    )
    result = type.cast(original)

    assert_same original, result
  end

  test "RequestType casts nil to nil" do
    type = ActiveAgent::Providers::RubyLLM::RequestType.new
    assert_nil type.cast(nil)
  end

  test "RequestType raises for unsupported type" do
    type = ActiveAgent::Providers::RubyLLM::RequestType.new

    assert_raises(ArgumentError) do
      type.cast(42)
    end
  end

  test "RequestType serializes Request" do
    type = ActiveAgent::Providers::RubyLLM::RequestType.new
    request = ActiveAgent::Providers::RubyLLM::Request.new(
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Hello" }]
    )
    serialized = type.serialize(request)

    assert_kind_of Hash, serialized
    assert_equal "gpt-4o-mini", serialized[:model]
  end

  test "RequestType serializes hash as-is" do
    type = ActiveAgent::Providers::RubyLLM::RequestType.new
    hash = { model: "gpt-4o-mini" }
    assert_equal hash, type.serialize(hash)
  end

  test "RequestType serializes nil as nil" do
    type = ActiveAgent::Providers::RubyLLM::RequestType.new
    assert_nil type.serialize(nil)
  end

  test "RequestType raises for unsupported serialize type" do
    type = ActiveAgent::Providers::RubyLLM::RequestType.new

    assert_raises(ArgumentError) do
      type.serialize(42)
    end
  end

  test "RequestType deserialize delegates to cast" do
    type = ActiveAgent::Providers::RubyLLM::RequestType.new
    request = type.deserialize({
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Hello" }]
    })

    assert_kind_of ActiveAgent::Providers::RubyLLM::Request, request
  end

  # --- EmbeddingRequestType ---

  test "EmbeddingRequestType casts hash to EmbeddingRequest" do
    type = ActiveAgent::Providers::RubyLLM::EmbeddingRequestType.new
    request = type.cast({
      model: "text-embedding-3-small",
      input: "Hello world"
    })

    assert_kind_of ActiveAgent::Providers::RubyLLM::EmbeddingRequest, request
    assert_equal "text-embedding-3-small", request.model
    assert_equal "Hello world", request.input
  end

  test "EmbeddingRequestType passes through EmbeddingRequest instances" do
    type = ActiveAgent::Providers::RubyLLM::EmbeddingRequestType.new
    original = ActiveAgent::Providers::RubyLLM::EmbeddingRequest.new(
      model: "text-embedding-3-small",
      input: "Hello"
    )
    result = type.cast(original)

    assert_same original, result
  end

  test "EmbeddingRequestType casts nil to nil" do
    type = ActiveAgent::Providers::RubyLLM::EmbeddingRequestType.new
    assert_nil type.cast(nil)
  end

  test "EmbeddingRequestType raises for unsupported type" do
    type = ActiveAgent::Providers::RubyLLM::EmbeddingRequestType.new

    assert_raises(ArgumentError) do
      type.cast(42)
    end
  end

  test "EmbeddingRequestType serializes EmbeddingRequest" do
    type = ActiveAgent::Providers::RubyLLM::EmbeddingRequestType.new
    request = ActiveAgent::Providers::RubyLLM::EmbeddingRequest.new(
      model: "text-embedding-3-small",
      input: "Hello"
    )
    serialized = type.serialize(request)

    assert_kind_of Hash, serialized
    assert_equal "text-embedding-3-small", serialized[:model]
  end

  test "EmbeddingRequestType serializes hash as-is" do
    type = ActiveAgent::Providers::RubyLLM::EmbeddingRequestType.new
    hash = { model: "text-embedding-3-small" }
    assert_equal hash, type.serialize(hash)
  end

  test "EmbeddingRequestType serializes nil as nil" do
    type = ActiveAgent::Providers::RubyLLM::EmbeddingRequestType.new
    assert_nil type.serialize(nil)
  end

  test "EmbeddingRequestType raises for unsupported serialize type" do
    type = ActiveAgent::Providers::RubyLLM::EmbeddingRequestType.new

    assert_raises(ArgumentError) do
      type.serialize(42)
    end
  end

  test "EmbeddingRequestType deserialize delegates to cast" do
    type = ActiveAgent::Providers::RubyLLM::EmbeddingRequestType.new
    request = type.deserialize({
      model: "text-embedding-3-small",
      input: "Hello"
    })

    assert_kind_of ActiveAgent::Providers::RubyLLM::EmbeddingRequest, request
  end
end
