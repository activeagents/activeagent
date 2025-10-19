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
    @original_config = ActiveAgent.configuration.deep_dup
    TestPrompt._prompt_provider_klass = nil
    TestPrompt._embed_provider_klass = nil
  end

  teardown do
    ActiveAgent.configuration.replace(@original_config)
    TestPrompt._prompt_provider_klass = nil
    TestPrompt._embed_provider_klass = nil
  end

  # Class method tests
  test "defines prompt provider class methods" do
    assert_respond_to TestPrompt, :prompt_provider=
    assert_respond_to TestPrompt, :configuration
    assert_respond_to TestPrompt, :provider_config_load
    assert_respond_to TestPrompt, :provider_load
    assert_respond_to TestPrompt, :prompt_provider_klass
  end

  test "defines embed provider class methods" do
    assert_respond_to TestPrompt, :embed_provider=
    assert_respond_to TestPrompt, :embed_provider_klass
  end

  # Instance method tests
  test "includes prompt_provider_klass instance delegation" do
    instance = TestPrompt.new
    assert_respond_to instance, :prompt_provider_klass
  end

  test "includes embed_provider_klass instance delegation" do
    instance = TestPrompt.new
    assert_respond_to instance, :embed_provider_klass
  end

  # prompt_provider= tests with Symbol/String
  test "prompt_provider= accepts symbol reference" do
    ActiveAgent.configuration[:test_provider] = { service: "MockProvider" }

    # Stub provider_load to return our mock
    TestPrompt.stub(:provider_load, MockProvider) do
      TestPrompt.prompt_provider = :test_provider
      assert_equal MockProvider, TestPrompt.prompt_provider_klass
    end
  end

  test "prompt_provider= accepts string reference" do
    ActiveAgent.configuration[:test_provider] = { service: "MockProvider" }

    TestPrompt.stub(:provider_load, MockProvider) do
      TestPrompt.prompt_provider = "test_provider"
      assert_equal MockProvider, TestPrompt.prompt_provider_klass
    end
  end

  # prompt_provider= tests with provider instances
  test "prompt_provider= accepts BaseProvider instance" do
    provider_instance = MockProvider.new

    TestPrompt.prompt_provider = provider_instance

    assert_equal provider_instance, TestPrompt.prompt_provider_klass
  end

  test "prompt_provider= raises ArgumentError for unsupported type" do
    assert_raises(ArgumentError) do
      TestPrompt.prompt_provider = 123
    end
  end

  # embed_provider= tests with Symbol/String
  test "embed_provider= accepts symbol reference" do
    ActiveAgent.configuration[:test_provider] = { service: "MockProvider" }

    # Stub provider_load to return our mock
    TestPrompt.stub(:provider_load, MockProvider) do
      TestPrompt.embed_provider = :test_provider
      assert_equal MockProvider, TestPrompt.embed_provider_klass
    end
  end

  test "embed_provider= accepts string reference" do
    ActiveAgent.configuration[:test_provider] = { service: "MockProvider" }

    TestPrompt.stub(:provider_load, MockProvider) do
      TestPrompt.embed_provider = "test_provider"
      assert_equal MockProvider, TestPrompt.embed_provider_klass
    end
  end

  # embed_provider= tests with provider instances
  test "embed_provider= accepts BaseProvider instance" do
    provider_instance = MockProvider.new

    TestPrompt.embed_provider = provider_instance

    assert_equal provider_instance, TestPrompt.embed_provider_klass
  end

  test "embed_provider= raises ArgumentError for unsupported type" do
    assert_raises(ArgumentError) do
      TestPrompt.embed_provider = 123
    end
  end

  # configuration tests
  test "configuration loads provider from config by symbol" do
    ActiveAgent.configuration[:test_provider] = { service: "MockProvider" }

    TestPrompt.stub(:provider_load, MockProvider) do
      result = TestPrompt.configuration(:test_provider)
      assert_equal MockProvider, result
    end
  end

  test "configuration merges additional options" do
    ActiveAgent.configuration[:test_provider] = { service: "MockProvider", model: "test-model" }

    TestPrompt.stub(:provider_load, MockProvider) do
      # Configuration should call provider_config_load which includes the merged options
      result = TestPrompt.configuration(:test_provider, temperature: 0.7)
      assert_equal MockProvider, result
    end
  end

  test "configuration raises error on LoadError" do
    ActiveAgent.configuration[:test_provider] = { service: "NonExistentProvider" }

    error = assert_raises(RuntimeError) do
      TestPrompt.configuration(:test_provider)
    end

    assert_includes error.message, "Failed to load provider"
  end

  # provider_config_load tests
  test "provider_config_load retrieves config by string key" do
    ActiveAgent.configuration["test_provider"] = { service: "TestService", model: "test-model" }

    config = TestPrompt.provider_config_load("test_provider")

    assert_equal "TestService", config[:service]
    assert_equal "test-model", config[:model]
  end

  test "provider_config_load retrieves config by symbol key" do
    ActiveAgent.configuration["test_provider"] = { service: "TestService", model: "test-model" }

    config = TestPrompt.provider_config_load(:test_provider)

    assert_equal "TestService", config[:service]
    assert_equal "test-model", config[:model]
  end

  test "provider_config_load checks environment-specific config" do
    ENV["RAILS_ENV"] = "test"
    ActiveAgent.configuration["test"] = { "test_provider" => { service: "EnvSpecific" } }

    config = TestPrompt.provider_config_load(:test_provider)

    assert_equal "EnvSpecific", config[:service]
  end

  test "provider_config_load returns empty hash when not found" do
    config = TestPrompt.provider_config_load(:nonexistent_provider)

    assert_equal({}, config)
  end

  test "provider_config_load deep symbolizes keys" do
    ActiveAgent.configuration["test_provider"] = { "service" => "Test", "nested" => { "key" => "value" } }

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

  # prompt_provider_klass tests
  test "prompt_provider_klass returns nil when not set" do
    assert_nil TestPrompt.prompt_provider_klass
  end

  test "prompt_provider_klass returns set provider" do
    TestPrompt._prompt_provider_klass = MockProvider

    assert_equal MockProvider, TestPrompt.prompt_provider_klass
  end

  test "prompt_provider_klass is accessible from instance" do
    TestPrompt._prompt_provider_klass = MockProvider
    instance = TestPrompt.new

    assert_equal MockProvider, instance.prompt_provider_klass
  end

  # embed_provider_klass tests
  test "embed_provider_klass returns nil when not set" do
    assert_nil TestPrompt.embed_provider_klass
  end

  test "embed_provider_klass returns set provider" do
    TestPrompt._embed_provider_klass = MockProvider

    assert_equal MockProvider, TestPrompt.embed_provider_klass
  end

  test "embed_provider_klass is accessible from instance" do
    TestPrompt._embed_provider_klass = MockProvider
    instance = TestPrompt.new

    assert_equal MockProvider, instance.embed_provider_klass
  end

  # Integration tests
  test "setting prompt provider by symbol configures class correctly" do
    ActiveAgent.configuration[:openai] = { service: "OpenAI", api_key: "test-key" }

    TestPrompt.stub(:provider_load, MockProvider) do
      TestPrompt.prompt_provider = :openai

      assert_equal MockProvider, TestPrompt.prompt_provider_klass
      assert_equal MockProvider, TestPrompt.new.prompt_provider_klass
    end
  end

  test "setting embed provider by symbol configures class correctly" do
    ActiveAgent.configuration[:openai] = { service: "OpenAI", api_key: "test-key" }

    TestPrompt.stub(:provider_load, MockProvider) do
      TestPrompt.embed_provider = :openai

      assert_equal MockProvider, TestPrompt.embed_provider_klass
      assert_equal MockProvider, TestPrompt.new.embed_provider_klass
    end
  end

  test "prompt provider configuration is inherited by instances" do
    provider = MockProvider.new
    TestPrompt.prompt_provider = provider

    instance1 = TestPrompt.new
    instance2 = TestPrompt.new

    assert_equal provider, instance1.prompt_provider_klass
    assert_equal provider, instance2.prompt_provider_klass
  end

  test "embed provider configuration is inherited by instances" do
    provider = MockProvider.new
    TestPrompt.embed_provider = provider

    instance1 = TestPrompt.new
    instance2 = TestPrompt.new

    assert_equal provider, instance1.embed_provider_klass
    assert_equal provider, instance2.embed_provider_klass
  end

  test "prompt provider can be changed at runtime" do
    provider1 = MockProvider.new
    provider2 = MockProvider.new

    TestPrompt.prompt_provider = provider1
    assert_equal provider1, TestPrompt.prompt_provider_klass

    TestPrompt.prompt_provider = provider2
    assert_equal provider2, TestPrompt.prompt_provider_klass
  end

  test "embed provider can be changed at runtime" do
    provider1 = MockProvider.new
    provider2 = MockProvider.new

    TestPrompt.embed_provider = provider1
    assert_equal provider1, TestPrompt.embed_provider_klass

    TestPrompt.embed_provider = provider2
    assert_equal provider2, TestPrompt.embed_provider_klass
  end

  test "prompt and embed providers can be set independently" do
    prompt_provider = MockProvider.new
    embed_provider = MockProvider.new

    TestPrompt.prompt_provider = prompt_provider
    TestPrompt.embed_provider = embed_provider

    assert_equal prompt_provider, TestPrompt.prompt_provider_klass
    assert_equal embed_provider, TestPrompt.embed_provider_klass
  end
end
