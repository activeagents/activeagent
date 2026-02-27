# frozen_string_literal: true

require "test_helper"

class BedrockProviderLoadingTest < ActiveSupport::TestCase
  test "loads BedrockProvider via bedrock_provider path" do
    require "active_agent/providers/bedrock_provider"

    assert defined?(ActiveAgent::Providers::BedrockProvider)
    assert defined?(ActiveAgent::Providers::Bedrock::Options)
  end

  test "provider concern loads Bedrock service correctly" do
    # Simulate how the provider concern loads providers
    service_name = "Bedrock"
    require "active_agent/providers/#{service_name.underscore}_provider"

    # Bedrock needs no remap — it resolves directly
    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS
    remapped = Hash.new(service_name).merge!(remaps)[service_name]

    assert_equal "Bedrock", remapped

    # The provider concern looks up "#{service_name.camelize}Provider"
    provider_class = ActiveAgent::Providers.const_get("#{remapped.camelize}Provider")
    assert_equal ActiveAgent::Providers::BedrockProvider, provider_class
  end
end
