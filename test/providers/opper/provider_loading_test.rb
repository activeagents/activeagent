# frozen_string_literal: true

require "test_helper"

class OpperProviderLoadingTest < ActiveSupport::TestCase
  test "loads OpperProvider via opper_provider path" do
    require "active_agent/providers/opper_provider"

    assert defined?(ActiveAgent::Providers::OpperProvider)
    assert defined?(ActiveAgent::Providers::Opper::Options)
  end

  test "provider concern loads Opper service correctly" do
    # Simulate how the provider concern loads providers
    service_name = "Opper"
    require "active_agent/providers/#{service_name.underscore}_provider"

    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS
    remapped = Hash.new(service_name).merge!(remaps)[service_name]

    assert_equal "Opper", remapped

    provider_class = ActiveAgent::Providers.const_get("#{remapped.camelize}Provider")
    assert_equal ActiveAgent::Providers::OpperProvider, provider_class
  end

  test "Opper options default to the Opper gateway and OPPER_API_KEY" do
    require "active_agent/providers/opper_provider"

    options = ActiveAgent::Providers::Opper::Options.new(api_key: "op-test")

    assert_equal "https://api.opper.ai/v3/compat", options.base_url
    assert_equal "op-test", options.api_key
  end
end
