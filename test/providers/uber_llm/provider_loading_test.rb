# frozen_string_literal: true

require "test_helper"

class UberLLMProviderLoadingTest < ActiveSupport::TestCase
  test "loads UberLLMProvider via uber_llm_provider path" do
    require "active_agent/providers/uber_llm_provider"

    assert defined?(ActiveAgent::Providers::UberLLMProvider)
    assert defined?(ActiveAgent::Providers::UberLLM::Options)
  end

  test "provider concern loads the UberLLM service correctly" do
    provider_class = Class.new(ActiveAgent::Base).provider_load("UberLLM")

    assert_equal ActiveAgent::Providers::UberLLMProvider, provider_class
  end

  test "generate_with :uber_llm and :uberllm resolve to UberLLMProvider without a config entry" do
    agent = Class.new(ActiveAgent::Base)

    assert_equal ActiveAgent::Providers::UberLLMProvider, agent.provider_setup(:uber_llm)
    assert_equal ActiveAgent::Providers::UberLLMProvider, agent.provider_setup(:uberllm)
  end

  test "service name remap handles Uberllm and UberLlm variations" do
    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS

    assert_equal "UberLLM", remaps["Uberllm"]
    assert_equal "UberLLM", remaps["UberLlm"]
  end

  test "UberLLM options default to the UberLLM API and UBERLLM_API_KEY" do
    require "active_agent/providers/uber_llm_provider"

    options = ActiveAgent::Providers::UberLLM::Options.new(api_key: "ull-test")

    assert_equal "https://api.uberllm.dev/v1", options.base_url
    assert_equal "ull-test", options.api_key
  end
end
