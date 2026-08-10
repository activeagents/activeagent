# frozen_string_literal: true

require "test_helper"

class AtlasCloudProviderLoadingTest < ActiveSupport::TestCase
  test "loads AtlasCloudProvider via atlas_cloud_provider path" do
    require "active_agent/providers/atlas_cloud_provider"

    assert defined?(ActiveAgent::Providers::AtlasCloudProvider)
    assert defined?(ActiveAgent::Providers::AtlasCloud::Options)
  end

  test "provider concern loads AtlasCloud service correctly" do
    provider_class = Class.new(ActiveAgent::Base).provider_load("AtlasCloud")

    assert_equal ActiveAgent::Providers::AtlasCloudProvider, provider_class
  end

  test "Atlas Cloud options use the provider endpoint and API key" do
    require "active_agent/providers/atlas_cloud_provider"

    options = ActiveAgent::Providers::AtlasCloud::Options.new(api_key: "atlas-test")

    assert_equal "https://api.atlascloud.ai/v1", options.base_url
    assert_equal "atlas-test", options.api_key
  end

  test "Atlas Cloud options resolve ATLASCLOUD_API_KEY" do
    require "active_agent/providers/atlas_cloud_provider"

    previous_key = ENV["ATLASCLOUD_API_KEY"]
    ENV["ATLASCLOUD_API_KEY"] = "atlas-env-test"

    options = ActiveAgent::Providers::AtlasCloud::Options.new

    assert_equal "atlas-env-test", options.api_key
  ensure
    ENV["ATLASCLOUD_API_KEY"] = previous_key
  end
end
