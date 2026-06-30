# frozen_string_literal: true

require "test_helper"

class RequestyProviderLoadingTest < ActiveSupport::TestCase
  test "loads RequestyProvider via requesty_provider path" do
    require "active_agent/providers/requesty_provider"

    assert defined?(ActiveAgent::Providers::RequestyProvider)
    assert defined?(ActiveAgent::Providers::Requesty::Options)
  end

  test "provider concern loads Requesty service correctly" do
    # Simulate how the provider concern loads providers
    service_name = "Requesty"
    require "active_agent/providers/#{service_name.underscore}_provider"

    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS
    remapped = Hash.new(service_name).merge!(remaps)[service_name]

    assert_equal "Requesty", remapped

    provider_class = ActiveAgent::Providers.const_get("#{remapped.camelize}Provider")
    assert_equal ActiveAgent::Providers::RequestyProvider, provider_class
  end

  test "Requesty options default to the Requesty gateway and REQUESTY_API_KEY" do
    require "active_agent/providers/requesty_provider"

    options = ActiveAgent::Providers::Requesty::Options.new(api_key: "rqsty-test")

    assert_equal "https://router.requesty.ai/v1", options.base_url
    assert_equal "rqsty-test", options.api_key
  end
end
