# frozen_string_literal: true

require "test_helper"
require "active_agent/action_prompt/concerns/provider"

class ProviderTest < ActiveSupport::TestCase
  # Test class that includes the Provider concern
  class TestPrompt
    include ActiveAgent::ActionPrompt::Provider
  end

  # Mock provider classes for testing
  class MockProvider < ActiveAgent::Providers::BaseProvider
    def initialize(options = {}); end
    def call; end
  end

  class MockAnthropicClient
    def initialize(api_key:); end
  end

  class MockOpenAIClient
    def initialize(access_token:); end
  end

  setup do
    @original_config = ActiveAgent.config.deep_dup
    TestPrompt._provider_klass = nil
  end

  teardown do
    ActiveAgent.config.replace(@original_config)
    TestPrompt._provider_klass = nil
  end

  # Class method tests
  test "defines provider class methods" do
    assert_respond_to TestPrompt, :provider=
    assert_respond_to TestPrompt, :configuration
    assert_respond_to TestPrompt, :provider_config_load
    assert_respond_to TestPrompt, :provider_load
    assert_respond_to TestPrompt, :provider_klass
  end

  # Instance method tests
  test "includes provider_klass instance delegation" do
    instance = TestPrompt.new
    assert_respond_to instance, :provider_klass
  end

  # provider= tests with Symbol/String
  test "provider= accepts symbol reference" do
    ActiveAgent.config[:test_provider] = { service: "MockProvider" }

    # Stub provider_load to return our mock
    TestPrompt.stub(:provider_load, MockProvider) do
      TestPrompt.provider = :test_provider
      assert_equal MockProvider, TestPrompt.provider_klass
    end
  end

  test "provider= accepts string reference" do
    ActiveAgent.config[:test_provider] = { service: "MockProvider" }

    TestPrompt.stub(:provider_load, MockProvider) do
      TestPrompt.provider = "test_provider"
      assert_equal MockProvider, TestPrompt.provider_klass
    end
  end

  # provider= tests with provider instances
  test "provider= accepts BaseProvider instance" do
    provider_instance = MockProvider.new

    TestPrompt.provider = provider_instance

    assert_equal provider_instance, TestPrompt.provider_klass
  end

  test "provider= raises ArgumentError for unsupported type" do
    assert_raises(ArgumentError) do
      TestPrompt.provider = 123
    end
  end

  # configuration tests
  test "configuration loads provider from config by symbol" do
    ActiveAgent.config[:test_provider] = { service: "MockProvider" }

    TestPrompt.stub(:provider_load, MockProvider) do
      result = TestPrompt.configuration(:test_provider)
      assert_equal MockProvider, result
    end
  end

  test "configuration merges additional options" do
    ActiveAgent.config[:test_provider] = { service: "MockProvider", model: "test-model" }

    TestPrompt.stub(:provider_load, MockProvider) do
      # Configuration should call provider_config_load which includes the merged options
      result = TestPrompt.configuration(:test_provider, temperature: 0.7)
      assert_equal MockProvider, result
    end
  end

  test "configuration raises error on LoadError" do
    ActiveAgent.config[:test_provider] = { service: "NonExistentProvider" }

    error = assert_raises(RuntimeError) do
      TestPrompt.configuration(:test_provider)
    end

    assert_includes error.message, "Failed to load provider"
  end

  # provider_config_load tests
  test "provider_config_load retrieves config by string key" do
    ActiveAgent.config["test_provider"] = { service: "TestService", model: "test-model" }

    config = TestPrompt.provider_config_load("test_provider")

    assert_equal "TestService", config[:service]
    assert_equal "test-model", config[:model]
  end

  test "provider_config_load retrieves config by symbol key" do
    ActiveAgent.config["test_provider"] = { service: "TestService", model: "test-model" }

    config = TestPrompt.provider_config_load(:test_provider)

    assert_equal "TestService", config[:service]
    assert_equal "test-model", config[:model]
  end

  test "provider_config_load checks environment-specific config" do
    ENV["RAILS_ENV"] = "test"
    ActiveAgent.config["test"] = { "test_provider" => { service: "EnvSpecific" } }

    config = TestPrompt.provider_config_load(:test_provider)

    assert_equal "EnvSpecific", config[:service]
  end

  test "provider_config_load returns empty hash when not found" do
    config = TestPrompt.provider_config_load(:nonexistent_provider)

    assert_equal({}, config)
  end

  test "provider_config_load deep symbolizes keys" do
    ActiveAgent.config["test_provider"] = { "service" => "Test", "nested" => { "key" => "value" } }

    config = TestPrompt.provider_config_load(:test_provider)

    assert_equal "Test", config[:service]
    assert_equal "value", config[:nested][:key]
  end

  # provider_load tests
  test "provider_load requires correct file path" do
    # Mock the require to verify correct path
    require_called_with = nil
    TestPrompt.stub(:require, ->(path) { require_called_with = path }) do
      begin
        TestPrompt.provider_load("OpenAI")
      rescue NameError
        # Expected since we're not actually loading the file
      end
    end

    assert_equal "active_agent/providers/open_ai_provider", require_called_with
  end

  test "provider_load converts service name to underscored file path" do
    require_called_with = nil
    TestPrompt.stub(:require, ->(path) { require_called_with = path }) do
      begin
        TestPrompt.provider_load("OpenRouter")
      rescue NameError
        # Expected
      end
    end

    assert_equal "active_agent/providers/open_router_provider", require_called_with
  end

  # provider_klass tests
  test "provider_klass returns nil when not set" do
    assert_nil TestPrompt.provider_klass
  end

  test "provider_klass returns set provider" do
    TestPrompt._provider_klass = MockProvider

    assert_equal MockProvider, TestPrompt.provider_klass
  end

  test "provider_klass is accessible from instance" do
    TestPrompt._provider_klass = MockProvider
    instance = TestPrompt.new

    assert_equal MockProvider, instance.provider_klass
  end

  # Integration tests
  test "setting provider by symbol configures class correctly" do
    ActiveAgent.config[:openai] = { service: "OpenAI", api_key: "test-key" }

    TestPrompt.stub(:provider_load, MockProvider) do
      TestPrompt.provider = :openai

      assert_equal MockProvider, TestPrompt.provider_klass
      assert_equal MockProvider, TestPrompt.new.provider_klass
    end
  end

  test "provider configuration is inherited by instances" do
    provider = MockProvider.new
    TestPrompt.provider = provider

    instance1 = TestPrompt.new
    instance2 = TestPrompt.new

    assert_equal provider, instance1.provider_klass
    assert_equal provider, instance2.provider_klass
  end

  test "provider can be changed at runtime" do
    provider1 = MockProvider.new
    provider2 = MockProvider.new

    TestPrompt.provider = provider1
    assert_equal provider1, TestPrompt.provider_klass

    TestPrompt.provider = provider2
    assert_equal provider2, TestPrompt.provider_klass
  end
end
