# frozen_string_literal: true

require "test_helper"

class AzureProviderLoadingTest < ActiveSupport::TestCase
  test "loads AzureProvider via azure_provider path" do
    require "active_agent/providers/azure_provider"

    assert defined?(ActiveAgent::Providers::AzureProvider)
    assert defined?(ActiveAgent::Providers::Azure::Options)
  end

  test "loads AzureProvider via azure_open_ai_provider path" do
    require "active_agent/providers/azure_open_ai_provider"

    assert defined?(ActiveAgent::Providers::AzureProvider)
  end

  test "loads AzureProvider via azureopenai_provider path" do
    require "active_agent/providers/azureopenai_provider"

    assert defined?(ActiveAgent::Providers::AzureProvider)
  end

  test "provider concern loads AzureOpenAI service correctly" do
    # Simulate how the provider concern loads providers
    service_name = "AzureOpenAI"
    require "active_agent/providers/#{service_name.underscore}_provider"

    # Check the remap works
    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS
    remapped = Hash.new(service_name).merge!(remaps)[service_name]

    assert_equal "AzureOpenAI", remapped

    # The provider concern looks up "#{service_name.camelize}Provider"
    provider_class = ActiveAgent::Providers.const_get("#{remapped.camelize}Provider")
    assert_equal ActiveAgent::Providers::AzureProvider, provider_class
  end

  test "service name remap handles AzureOpenai variation" do
    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS

    assert_equal "AzureOpenAI", remaps["AzureOpenai"]
    assert_equal "AzureOpenAI", remaps["Azureopenai"]
  end
end
