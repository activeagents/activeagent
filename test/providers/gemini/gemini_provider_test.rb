# frozen_string_literal: true

require "test_helper"

GEMINI_PROVIDER_OPENAI_AVAILABLE = begin
  require "openai"
  true
rescue LoadError
  warn "OpenAI gem not available, skipping Gemini provider tests"
  false
end

require_relative "../../../lib/active_agent/providers/gemini_provider" if GEMINI_PROVIDER_OPENAI_AVAILABLE

class GeminiProviderTest < ActiveSupport::TestCase
  setup do
    skip "OpenAI gem not available" unless GEMINI_PROVIDER_OPENAI_AVAILABLE
    @valid_config = {
      service: "Gemini",
      api_key: "test-api-key",
      messages: [ { role: "user", content: "Hello" } ]
    }
  end

  test "service_name returns Gemini" do
    assert_equal "Gemini", ActiveAgent::Providers::GeminiProvider.service_name
  end

  test "options_klass returns Gemini::Options" do
    assert_equal(
      ActiveAgent::Providers::Gemini::Options,
      ActiveAgent::Providers::GeminiProvider.options_klass
    )
  end

  test "prompt_request_type returns Gemini::RequestType" do
    request_type = ActiveAgent::Providers::GeminiProvider.prompt_request_type

    # Gemini::RequestType is aliased to OpenAI::Chat::RequestType
    assert_instance_of ActiveAgent::Providers::OpenAI::Chat::RequestType, request_type
  end

  test "embed_request_type returns OpenAI::Embedding::RequestType" do
    request_type = ActiveAgent::Providers::GeminiProvider.embed_request_type

    # Gemini::Embedding::RequestType is aliased to OpenAI::Embedding::RequestType
    assert_instance_of ActiveAgent::Providers::OpenAI::Embedding::RequestType, request_type
  end

  test "initializes provider with valid configuration" do
    provider = ActiveAgent::Providers::GeminiProvider.new(@valid_config)

    assert_instance_of ActiveAgent::Providers::GeminiProvider, provider
  end

  test "inherits from OpenAI::ChatProvider" do
    assert ActiveAgent::Providers::GeminiProvider < ActiveAgent::Providers::OpenAI::ChatProvider
  end

  test "client returns OpenAI::Client instance" do
    provider = ActiveAgent::Providers::GeminiProvider.new(@valid_config)
    client = provider.client

    assert_kind_of ::OpenAI::Client, client
  end
end
