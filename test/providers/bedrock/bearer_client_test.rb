# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/bedrock_provider"

class BedrockBearerClientTest < ActiveSupport::TestCase
  test "initializes with region and bearer token" do
    client = ActiveAgent::Providers::Bedrock::BearerClient.new(
      aws_region: "eu-west-2",
      bearer_token: "test-token"
    )

    assert_equal "eu-west-2", client.aws_region
  end

  test "sets auth_token from bearer_token parameter" do
    client = ActiveAgent::Providers::Bedrock::BearerClient.new(
      aws_region: "eu-west-2",
      bearer_token: "test-token"
    )

    assert_equal "test-token", client.auth_token
  end

  test "sets default base_url from aws_region" do
    client = ActiveAgent::Providers::Bedrock::BearerClient.new(
      aws_region: "us-east-1",
      bearer_token: "test-token"
    )

    assert_equal "us-east-1", client.aws_region
  end

  test "allows custom base_url" do
    client = ActiveAgent::Providers::Bedrock::BearerClient.new(
      aws_region: "eu-west-2",
      bearer_token: "test-token",
      base_url: "https://custom-bedrock.example.com"
    )

    assert_instance_of ActiveAgent::Providers::Bedrock::BearerClient, client
  end

  test "inherits from Anthropic::Client" do
    assert ActiveAgent::Providers::Bedrock::BearerClient < ::Anthropic::Client
  end

  test "has messages resource" do
    client = ActiveAgent::Providers::Bedrock::BearerClient.new(
      aws_region: "eu-west-2",
      bearer_token: "test-token"
    )

    assert_instance_of ::Anthropic::Resources::Messages, client.messages
  end

  test "has completions resource" do
    client = ActiveAgent::Providers::Bedrock::BearerClient.new(
      aws_region: "eu-west-2",
      bearer_token: "test-token"
    )

    assert_instance_of ::Anthropic::Resources::Completions, client.completions
  end

  test "has beta resource" do
    client = ActiveAgent::Providers::Bedrock::BearerClient.new(
      aws_region: "eu-west-2",
      bearer_token: "test-token"
    )

    assert_instance_of ::Anthropic::Resources::Beta, client.beta
  end
end
