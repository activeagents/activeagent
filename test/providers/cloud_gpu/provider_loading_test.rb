# frozen_string_literal: true

require "test_helper"

class CloudGPUProviderLoadingTest < ActiveSupport::TestCase
  test "loads CloudGPUProvider via cloud_gpu_provider path" do
    require "active_agent/providers/cloud_gpu_provider"

    assert defined?(ActiveAgent::Providers::CloudGPUProvider)
    assert defined?(ActiveAgent::Providers::CloudGPU::Options)
  end

  test "provider concern loads CloudGPU service correctly" do
    # Simulate how the provider concern loads providers
    service_name = "CloudGPU"
    require "active_agent/providers/#{service_name.underscore}_provider"

    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS
    remapped = Hash.new(service_name).merge!(remaps)[service_name]

    assert_equal "CloudGPU", remapped

    provider_class = ActiveAgent::Providers.const_get("#{remapped.camelize}Provider")
    assert_equal ActiveAgent::Providers::CloudGPUProvider, provider_class
  end

  test "CloudGPU options default to the CloudGPU API and CLOUDGPU_API_KEY" do
    require "active_agent/providers/cloud_gpu_provider"

    options = ActiveAgent::Providers::CloudGPU::Options.new(api_key: "cg-test")

    assert_equal "https://cloudgpu.app/v1", options.base_url
    assert_equal "cg-test", options.api_key
  end
end
