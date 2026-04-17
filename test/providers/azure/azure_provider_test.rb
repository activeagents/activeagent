# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/azure_provider"

class AzureProviderTest < ActiveSupport::TestCase
  setup do
    @valid_config = {
      service: "AzureOpenAI",
      api_key: "test-api-key",
      azure_resource: "mycompany",
      deployment_id: "gpt-4-deployment",
      api_version: "2024-10-21",
      messages: [ { role: "user", content: "Hello" } ]
    }
  end

  test "service_name returns AzureOpenAI" do
    assert_equal "AzureOpenAI", ActiveAgent::Providers::AzureProvider.service_name
  end

  test "options_klass returns Azure::Options" do
    assert_equal(
      ActiveAgent::Providers::Azure::Options,
      ActiveAgent::Providers::AzureProvider.options_klass
    )
  end

  test "prompt_request_type returns OpenAI::Chat::RequestType" do
    request_type = ActiveAgent::Providers::AzureProvider.prompt_request_type

    assert_instance_of ActiveAgent::Providers::OpenAI::Chat::RequestType, request_type
  end

  test "embed_request_type returns OpenAI::Embedding::RequestType" do
    request_type = ActiveAgent::Providers::AzureProvider.embed_request_type

    assert_instance_of ActiveAgent::Providers::OpenAI::Embedding::RequestType, request_type
  end

  test "initializes provider with valid configuration" do
    provider = ActiveAgent::Providers::AzureProvider.new(@valid_config)

    assert_instance_of ActiveAgent::Providers::AzureProvider, provider
  end

  test "client is configured with Azure-specific settings" do
    provider = ActiveAgent::Providers::AzureProvider.new(@valid_config)
    client = provider.client

    assert_kind_of ::OpenAI::Client, client
    assert_instance_of ActiveAgent::Providers::AzureProvider::AzureClient, client
  end

  test "inherits from OpenAI::ChatProvider" do
    assert ActiveAgent::Providers::AzureProvider < ActiveAgent::Providers::OpenAI::ChatProvider
  end

  test "AzureClient stores api_version" do
    provider = ActiveAgent::Providers::AzureProvider.new(@valid_config)
    client = provider.client

    assert_equal "2024-10-21", client.api_version
  end

  test "AzureOpenAIProvider is an alias for AzureProvider" do
    assert_equal(
      ActiveAgent::Providers::AzureProvider,
      ActiveAgent::Providers::AzureOpenAIProvider
    )
  end
end
