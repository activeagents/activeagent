# frozen_string_literal: true

require "test_helper"

class CheaperInferenceProviderLoadingTest < ActiveSupport::TestCase
  test "loads CheaperInferenceProvider via cheaper_inference_provider path" do
    require "active_agent/providers/cheaper_inference_provider"

    assert defined?(ActiveAgent::Providers::CheaperInferenceProvider)
    assert defined?(ActiveAgent::Providers::CheaperInference::Options)
  end

  test "provider concern loads CheaperInference service correctly" do
    # Simulate how the provider concern loads providers
    service_name = "CheaperInference"
    require "active_agent/providers/#{service_name.underscore}_provider"

    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS
    remapped = Hash.new(service_name).merge!(remaps)[service_name]

    assert_equal "CheaperInference", remapped

    provider_class = ActiveAgent::Providers.const_get("#{remapped.camelize}Provider")
    assert_equal ActiveAgent::Providers::CheaperInferenceProvider, provider_class
  end

  test "CheaperInference options default to the Cheaper Inference gateway and CHEAPER_INFERENCE_API_KEY" do
    require "active_agent/providers/cheaper_inference_provider"

    options = ActiveAgent::Providers::CheaperInference::Options.new(api_key: "ci-test")

    assert_equal "https://api.cheaperinference.com/v1", options.base_url
    assert_equal "ci-test", options.api_key
  end
end
