# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/azure_provider"

class AzureOptionsTest < ActiveSupport::TestCase
  setup do
    @valid_options = {
      api_key: "test-api-key",
      azure_resource: "mycompany",
      deployment_id: "gpt-4-deployment"
    }
  end

  test "initializes with valid options" do
    original_version = ENV["AZURE_OPENAI_API_VERSION"]
    ENV.delete("AZURE_OPENAI_API_VERSION")

    options = ActiveAgent::Providers::Azure::Options.new(@valid_options)

    assert_equal "test-api-key", options.api_key
    assert_equal "mycompany", options.azure_resource
    assert_equal "gpt-4-deployment", options.deployment_id
    assert_equal "2024-10-21", options.api_version
  ensure
    ENV["AZURE_OPENAI_API_VERSION"] = original_version
  end

  test "allows custom api_version" do
    options = ActiveAgent::Providers::Azure::Options.new(
      @valid_options.merge(api_version: "2024-02-15-preview")
    )

    assert_equal "2024-02-15-preview", options.api_version
  end

  test "builds correct base_url" do
    options = ActiveAgent::Providers::Azure::Options.new(@valid_options)

    assert_equal(
      "https://mycompany.openai.azure.com/openai/deployments/gpt-4-deployment",
      options.base_url
    )
  end

  test "returns correct extra_headers with api-key" do
    options = ActiveAgent::Providers::Azure::Options.new(@valid_options)

    assert_equal({ "api-key" => "test-api-key" }, options.extra_headers)
  end

  test "returns correct extra_query with api-version" do
    original_version = ENV["AZURE_OPENAI_API_VERSION"]
    ENV.delete("AZURE_OPENAI_API_VERSION")

    options = ActiveAgent::Providers::Azure::Options.new(@valid_options)

    assert_equal({ "api-version" => "2024-10-21" }, options.extra_query)
  ensure
    ENV["AZURE_OPENAI_API_VERSION"] = original_version
  end

  test "validates presence of api_key" do
    original_key = ENV["AZURE_OPENAI_API_KEY"]
    ENV.delete("AZURE_OPENAI_API_KEY")

    options = ActiveAgent::Providers::Azure::Options.new(
      @valid_options.except(:api_key)
    )

    assert_not options.valid?
    assert_includes options.errors[:api_key], "can't be blank"
  ensure
    ENV["AZURE_OPENAI_API_KEY"] = original_key
  end

  test "validates presence of azure_resource" do
    options = ActiveAgent::Providers::Azure::Options.new(
      @valid_options.except(:azure_resource)
    )

    assert_not options.valid?
    assert_includes options.errors[:azure_resource], "can't be blank"
  end

  test "validates presence of deployment_id" do
    options = ActiveAgent::Providers::Azure::Options.new(
      @valid_options.except(:deployment_id)
    )

    assert_not options.valid?
    assert_includes options.errors[:deployment_id], "can't be blank"
  end

  test "resolves api_key from environment variable" do
    original_key = ENV["AZURE_OPENAI_API_KEY"]
    ENV["AZURE_OPENAI_API_KEY"] = "env-api-key"

    options = ActiveAgent::Providers::Azure::Options.new(
      azure_resource: "mycompany",
      deployment_id: "gpt-4"
    )

    assert_equal "env-api-key", options.api_key
  ensure
    ENV["AZURE_OPENAI_API_KEY"] = original_key
  end

  test "prefers explicit api_key over environment variable" do
    original_key = ENV["AZURE_OPENAI_API_KEY"]
    ENV["AZURE_OPENAI_API_KEY"] = "env-api-key"

    options = ActiveAgent::Providers::Azure::Options.new(@valid_options)

    assert_equal "test-api-key", options.api_key
  ensure
    ENV["AZURE_OPENAI_API_KEY"] = original_key
  end

  test "resolves api_version from environment variable" do
    original_version = ENV["AZURE_OPENAI_API_VERSION"]
    ENV["AZURE_OPENAI_API_VERSION"] = "2025-01-01-preview"

    options = ActiveAgent::Providers::Azure::Options.new(@valid_options)

    assert_equal "2025-01-01-preview", options.api_version
  ensure
    ENV["AZURE_OPENAI_API_VERSION"] = original_version
  end

  test "prefers explicit api_version over environment variable" do
    original_version = ENV["AZURE_OPENAI_API_VERSION"]
    ENV["AZURE_OPENAI_API_VERSION"] = "2025-01-01-preview"

    options = ActiveAgent::Providers::Azure::Options.new(
      @valid_options.merge(api_version: "2024-02-15-preview")
    )

    assert_equal "2024-02-15-preview", options.api_version
  ensure
    ENV["AZURE_OPENAI_API_VERSION"] = original_version
  end

  # Tests for direct host support (Azure AI Foundry, Cognitive Services, custom domains)
  test "allows direct host configuration without azure_resource and deployment_id" do
    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-api-key",
      host: "https://mycompany.cognitiveservices.azure.com/openai/deployments/gpt-4",
      api_version: "2024-10-21"
    )

    assert options.valid?, "Expected options to be valid, got errors: #{options.errors.full_messages}"
    assert_equal "https://mycompany.cognitiveservices.azure.com/openai/deployments/gpt-4", options.base_url
  end

  test "uses direct host for base_url when provided" do
    custom_host = "https://custom.azure.com/openai/deployments/my-model"
    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-api-key",
      host: custom_host
    )

    assert_equal custom_host, options.base_url
  end

  test "uses base_url alias for direct host configuration" do
    custom_url = "https://mycompany.cognitiveservices.azure.com/openai/deployments/gpt-4.1"
    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-api-key",
      base_url: custom_url
    )

    assert_equal custom_url, options.base_url
  end

  test "prefers host over azure_resource and deployment_id" do
    custom_host = "https://custom.azure.com/path"
    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-api-key",
      host: custom_host,
      azure_resource: "ignored",
      deployment_id: "also-ignored"
    )

    assert_equal custom_host, options.base_url
  end

  test "validates presence of azure_resource only when host not provided" do
    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-api-key",
      deployment_id: "gpt-4"
      # Missing both host and azure_resource
    )

    assert_not options.valid?
    assert_includes options.errors[:azure_resource], "can't be blank"
  end

  test "validates presence of deployment_id only when host not provided" do
    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-api-key",
      azure_resource: "mycompany"
      # Missing both host and deployment_id
    )

    assert_not options.valid?
    assert_includes options.errors[:deployment_id], "can't be blank"
  end

  test "skips azure_resource validation when host provided" do
    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-api-key",
      host: "https://custom.azure.com/path"
      # No azure_resource - should be valid
    )

    assert options.valid?, "Expected valid with host, got: #{options.errors.full_messages}"
  end

  test "skips deployment_id validation when host provided" do
    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-api-key",
      host: "https://custom.azure.com/path"
      # No deployment_id - should be valid
    )

    assert options.valid?, "Expected valid with host, got: #{options.errors.full_messages}"
  end

  test "is valid with only host and api_key" do
    original_version = ENV["AZURE_OPENAI_API_VERSION"]
    ENV.delete("AZURE_OPENAI_API_VERSION")

    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-api-key",
      host: "https://myhost.azure.com/path"
    )

    assert options.valid?, "Expected options to be valid with just host and api_key, got: #{options.errors.full_messages}"
  ensure
    ENV["AZURE_OPENAI_API_VERSION"] = original_version
  end

  test "still returns correct extra_headers when using direct host" do
    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "my-secret-key",
      host: "https://custom.azure.com/path"
    )

    assert_equal({ "api-key" => "my-secret-key" }, options.extra_headers)
  end

  test "still returns correct extra_query when using direct host" do
    original_version = ENV["AZURE_OPENAI_API_VERSION"]
    ENV.delete("AZURE_OPENAI_API_VERSION")

    options = ActiveAgent::Providers::Azure::Options.new(
      api_key: "test-key",
      host: "https://custom.azure.com/path",
      api_version: "2025-01-01-preview"
    )

    assert_equal({ "api-version" => "2025-01-01-preview" }, options.extra_query)
  ensure
    ENV["AZURE_OPENAI_API_VERSION"] = original_version
  end
end
