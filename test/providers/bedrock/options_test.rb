# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/bedrock_provider"

class BedrockOptionsTest < ActiveSupport::TestCase
  setup do
    @valid_options = {
      aws_region: "eu-west-2",
      aws_access_key: "test-access-key",
      aws_secret_key: "test-secret-key"
    }
  end

  test "initializes with valid options" do
    options = ActiveAgent::Providers::Bedrock::Options.new(@valid_options)

    assert_equal "eu-west-2", options.aws_region
    assert_equal "test-access-key", options.aws_access_key
    assert_equal "test-secret-key", options.aws_secret_key
  end

  test "initializes with session token" do
    options = ActiveAgent::Providers::Bedrock::Options.new(
      @valid_options.merge(aws_session_token: "test-session-token")
    )

    assert_equal "test-session-token", options.aws_session_token
  end

  test "initializes with profile" do
    options = ActiveAgent::Providers::Bedrock::Options.new(
      @valid_options.merge(aws_profile: "tembo-dev")
    )

    assert_equal "tembo-dev", options.aws_profile
  end

  test "allows custom base_url" do
    custom_url = "https://custom-bedrock.example.com"
    options = ActiveAgent::Providers::Bedrock::Options.new(
      @valid_options.merge(base_url: custom_url)
    )

    assert_equal custom_url, options.base_url
  end

  test "has default max_retries" do
    options = ActiveAgent::Providers::Bedrock::Options.new(@valid_options)

    assert_equal ::Anthropic::Client::DEFAULT_MAX_RETRIES, options.max_retries
  end

  test "has default timeout" do
    options = ActiveAgent::Providers::Bedrock::Options.new(@valid_options)

    assert_equal ::Anthropic::Client::DEFAULT_TIMEOUT_IN_SECONDS, options.timeout
  end

  test "allows custom max_retries" do
    options = ActiveAgent::Providers::Bedrock::Options.new(
      @valid_options.merge(max_retries: 5)
    )

    assert_equal 5, options.max_retries
  end

  test "allows custom timeout" do
    options = ActiveAgent::Providers::Bedrock::Options.new(
      @valid_options.merge(timeout: 120.0)
    )

    assert_equal 120.0, options.timeout
  end

  test "has default initial_retry_delay" do
    options = ActiveAgent::Providers::Bedrock::Options.new(@valid_options)

    assert_equal ::Anthropic::Client::DEFAULT_INITIAL_RETRY_DELAY, options.initial_retry_delay
  end

  test "has default max_retry_delay" do
    options = ActiveAgent::Providers::Bedrock::Options.new(@valid_options)

    assert_equal ::Anthropic::Client::DEFAULT_MAX_RETRY_DELAY, options.max_retry_delay
  end

  test "allows custom initial_retry_delay" do
    options = ActiveAgent::Providers::Bedrock::Options.new(
      @valid_options.merge(initial_retry_delay: 2.0)
    )

    assert_equal 2.0, options.initial_retry_delay
  end

  test "allows custom max_retry_delay" do
    options = ActiveAgent::Providers::Bedrock::Options.new(
      @valid_options.merge(max_retry_delay: 30.0)
    )

    assert_equal 30.0, options.max_retry_delay
  end

  test "resolves aws_region from AWS_REGION environment variable" do
    original_region = ENV["AWS_REGION"]
    original_default_region = ENV["AWS_DEFAULT_REGION"]
    ENV["AWS_REGION"] = "us-east-1"
    ENV.delete("AWS_DEFAULT_REGION")

    options = ActiveAgent::Providers::Bedrock::Options.new(
      aws_access_key: "test-key",
      aws_secret_key: "test-secret"
    )

    assert_equal "us-east-1", options.aws_region
  ensure
    ENV["AWS_REGION"] = original_region
    ENV["AWS_DEFAULT_REGION"] = original_default_region
  end

  test "resolves aws_region from AWS_DEFAULT_REGION environment variable" do
    original_region = ENV["AWS_REGION"]
    original_default_region = ENV["AWS_DEFAULT_REGION"]
    ENV.delete("AWS_REGION")
    ENV["AWS_DEFAULT_REGION"] = "eu-central-1"

    options = ActiveAgent::Providers::Bedrock::Options.new(
      aws_access_key: "test-key",
      aws_secret_key: "test-secret"
    )

    assert_equal "eu-central-1", options.aws_region
  ensure
    ENV["AWS_REGION"] = original_region
    ENV["AWS_DEFAULT_REGION"] = original_default_region
  end

  test "prefers explicit aws_region over environment variable" do
    original_region = ENV["AWS_REGION"]
    ENV["AWS_REGION"] = "us-east-1"

    options = ActiveAgent::Providers::Bedrock::Options.new(@valid_options)

    assert_equal "eu-west-2", options.aws_region
  ensure
    ENV["AWS_REGION"] = original_region
  end

  test "resolves aws_access_key from environment variable" do
    original_key = ENV["AWS_ACCESS_KEY_ID"]
    ENV["AWS_ACCESS_KEY_ID"] = "env-access-key"

    options = ActiveAgent::Providers::Bedrock::Options.new(
      aws_region: "eu-west-2",
      aws_secret_key: "test-secret"
    )

    assert_equal "env-access-key", options.aws_access_key
  ensure
    ENV["AWS_ACCESS_KEY_ID"] = original_key
  end

  test "prefers explicit aws_access_key over environment variable" do
    original_key = ENV["AWS_ACCESS_KEY_ID"]
    ENV["AWS_ACCESS_KEY_ID"] = "env-access-key"

    options = ActiveAgent::Providers::Bedrock::Options.new(@valid_options)

    assert_equal "test-access-key", options.aws_access_key
  ensure
    ENV["AWS_ACCESS_KEY_ID"] = original_key
  end

  test "resolves aws_secret_key from environment variable" do
    original_key = ENV["AWS_SECRET_ACCESS_KEY"]
    ENV["AWS_SECRET_ACCESS_KEY"] = "env-secret-key"

    options = ActiveAgent::Providers::Bedrock::Options.new(
      aws_region: "eu-west-2",
      aws_access_key: "test-key"
    )

    assert_equal "env-secret-key", options.aws_secret_key
  ensure
    ENV["AWS_SECRET_ACCESS_KEY"] = original_key
  end

  test "resolves aws_session_token from environment variable" do
    original_token = ENV["AWS_SESSION_TOKEN"]
    ENV["AWS_SESSION_TOKEN"] = "env-session-token"

    options = ActiveAgent::Providers::Bedrock::Options.new(@valid_options)

    assert_equal "env-session-token", options.aws_session_token
  ensure
    ENV["AWS_SESSION_TOKEN"] = original_token
  end

  test "resolves aws_profile from environment variable" do
    original_profile = ENV["AWS_PROFILE"]
    ENV["AWS_PROFILE"] = "env-profile"

    options = ActiveAgent::Providers::Bedrock::Options.new(@valid_options)

    assert_equal "env-profile", options.aws_profile
  ensure
    ENV["AWS_PROFILE"] = original_profile
  end

  test "initializes with bearer token" do
    options = ActiveAgent::Providers::Bedrock::Options.new(
      aws_region: "eu-west-2",
      aws_bearer_token: "test-bearer-token"
    )

    assert_equal "test-bearer-token", options.aws_bearer_token
  end

  test "resolves aws_bearer_token from environment variable" do
    original_token = ENV["AWS_BEARER_TOKEN_BEDROCK"]
    ENV["AWS_BEARER_TOKEN_BEDROCK"] = "env-bearer-token"

    options = ActiveAgent::Providers::Bedrock::Options.new(
      aws_region: "eu-west-2"
    )

    assert_equal "env-bearer-token", options.aws_bearer_token
  ensure
    ENV["AWS_BEARER_TOKEN_BEDROCK"] = original_token
  end

  test "prefers explicit aws_bearer_token over environment variable" do
    original_token = ENV["AWS_BEARER_TOKEN_BEDROCK"]
    ENV["AWS_BEARER_TOKEN_BEDROCK"] = "env-bearer-token"

    options = ActiveAgent::Providers::Bedrock::Options.new(
      aws_region: "eu-west-2",
      aws_bearer_token: "explicit-bearer-token"
    )

    assert_equal "explicit-bearer-token", options.aws_bearer_token
  ensure
    ENV["AWS_BEARER_TOKEN_BEDROCK"] = original_token
  end

  test "serialize excludes sensitive credential fields" do
    options = ActiveAgent::Providers::Bedrock::Options.new(
      @valid_options.merge(
        aws_session_token: "test-token",
        aws_profile: "test-profile",
        aws_bearer_token: "test-bearer-token"
      )
    )

    serialized = options.serialize

    assert_equal "eu-west-2", serialized[:aws_region]
    assert_nil serialized[:aws_access_key]
    assert_nil serialized[:aws_secret_key]
    assert_nil serialized[:aws_session_token]
    assert_nil serialized[:aws_profile]
    assert_nil serialized[:aws_bearer_token]
  end

  test "serialize includes non-credential fields" do
    options = ActiveAgent::Providers::Bedrock::Options.new(
      @valid_options.merge(base_url: "https://custom.example.com")
    )

    serialized = options.serialize

    assert_equal "eu-west-2", serialized[:aws_region]
    assert_equal "https://custom.example.com", serialized[:base_url]
  end
end
