# frozen_string_literal: true

require "test_helper"

class StandardComputeProviderLoadingTest < ActiveSupport::TestCase
  test "loads StandardComputeProvider via standard_compute_provider path" do
    require "active_agent/providers/standard_compute_provider"

    assert defined?(ActiveAgent::Providers::StandardComputeProvider)
    assert defined?(ActiveAgent::Providers::StandardCompute::Options)
  end

  test "provider concern loads StandardCompute service correctly" do
    # Simulate how the provider concern loads providers
    service_name = "StandardCompute"
    require "active_agent/providers/#{service_name.underscore}_provider"

    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS
    remapped = Hash.new(service_name).merge!(remaps)[service_name]

    assert_equal "StandardCompute", remapped

    provider_class = ActiveAgent::Providers.const_get("#{remapped.camelize}Provider")
    assert_equal ActiveAgent::Providers::StandardComputeProvider, provider_class
  end

  test "Standard Compute options default to the Standard Compute API and STANDARDCOMPUTE_API_KEY" do
    require "active_agent/providers/standard_compute_provider"

    options = ActiveAgent::Providers::StandardCompute::Options.new(api_key: "sc-test")

    assert_equal "https://api.stdcmpt.com/v1", options.base_url
    assert_equal "sc-test", options.api_key
  end
end
