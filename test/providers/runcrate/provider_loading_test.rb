# frozen_string_literal: true

require "test_helper"

class RuncrateProviderLoadingTest < ActiveSupport::TestCase
  test "loads RuncrateProvider via runcrate_provider path" do
    require "active_agent/providers/runcrate_provider"

    assert defined?(ActiveAgent::Providers::RuncrateProvider)
    assert defined?(ActiveAgent::Providers::Runcrate::Options)
  end

  test "provider concern loads Runcrate service correctly" do
    # Simulate how the provider concern loads providers
    service_name = "Runcrate"
    require "active_agent/providers/#{service_name.underscore}_provider"

    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS
    remapped = Hash.new(service_name).merge!(remaps)[service_name]

    assert_equal "Runcrate", remapped

    provider_class = ActiveAgent::Providers.const_get("#{remapped.camelize}Provider")
    assert_equal ActiveAgent::Providers::RuncrateProvider, provider_class
  end

  test "Runcrate options default to the Runcrate API and RUNCRATE_API_KEY" do
    require "active_agent/providers/runcrate_provider"

    options = ActiveAgent::Providers::Runcrate::Options.new(api_key: "rc-test")

    assert_equal "https://api.runcrate.ai/v1", options.base_url
    assert_equal "rc-test", options.api_key
  end
end
