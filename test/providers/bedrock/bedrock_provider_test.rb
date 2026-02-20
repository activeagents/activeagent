# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/bedrock_provider"

class BedrockProviderTest < ActiveSupport::TestCase
  setup do
    @valid_config = {
      service: "Bedrock",
      aws_region: "eu-west-2",
      aws_access_key: "test-access-key",
      aws_secret_key: "test-secret-key",
      model: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0",
      messages: [ { role: "user", content: "Hello" } ]
    }
  end

  test "service_name returns Bedrock" do
    assert_equal "Bedrock", ActiveAgent::Providers::BedrockProvider.service_name
  end

  test "options_klass returns Bedrock::Options" do
    assert_equal(
      ActiveAgent::Providers::Bedrock::Options,
      ActiveAgent::Providers::BedrockProvider.options_klass
    )
  end

  test "prompt_request_type returns Anthropic::RequestType" do
    request_type = ActiveAgent::Providers::BedrockProvider.prompt_request_type

    assert_instance_of ActiveAgent::Providers::Anthropic::RequestType, request_type
  end

  test "initializes provider with valid configuration" do
    provider = ActiveAgent::Providers::BedrockProvider.new(@valid_config)

    assert_instance_of ActiveAgent::Providers::BedrockProvider, provider
  end

  test "client returns an Anthropic::BedrockClient instance" do
    provider = ActiveAgent::Providers::BedrockProvider.new(@valid_config)
    client = provider.client

    assert_instance_of ::Anthropic::Helpers::Bedrock::Client, client
  end

  test "client is memoized" do
    provider = ActiveAgent::Providers::BedrockProvider.new(@valid_config)

    assert_same provider.client, provider.client
  end

  test "inherits from AnthropicProvider" do
    assert ActiveAgent::Providers::BedrockProvider < ActiveAgent::Providers::AnthropicProvider
  end

  test "client passes AWS credentials from options" do
    provider = ActiveAgent::Providers::BedrockProvider.new(@valid_config)
    client = provider.client

    assert_equal "eu-west-2", client.aws_region
  end

  test "client returns BearerClient when bearer token is configured" do
    bearer_config = {
      service: "Bedrock",
      aws_region: "eu-west-2",
      aws_bearer_token: "test-bearer-token",
      model: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0",
      messages: [ { role: "user", content: "Hello" } ]
    }

    provider = ActiveAgent::Providers::BedrockProvider.new(bearer_config)
    client = provider.client

    assert_instance_of ActiveAgent::Providers::Bedrock::BearerClient, client
  end

  test "client returns Anthropic::BedrockClient when no bearer token" do
    provider = ActiveAgent::Providers::BedrockProvider.new(@valid_config)
    client = provider.client

    assert_instance_of ::Anthropic::Helpers::Bedrock::Client, client
  end

  test "bearer client is memoized" do
    bearer_config = {
      service: "Bedrock",
      aws_region: "eu-west-2",
      aws_bearer_token: "test-bearer-token",
      model: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
    }

    provider = ActiveAgent::Providers::BedrockProvider.new(bearer_config)

    assert_same provider.client, provider.client
  end
end
