require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "cloud_gpu/_types"

module ActiveAgent
  module Providers
    # Provides access to CloudGPU's OpenAI-compatible model API.
    #
    # Extends the OpenAI provider to work with CloudGPU's OpenAI-compatible
    # API. Model ids are the names CloudGPU lists at +/v1/models+
    # (e.g. +deepseek-v4-flash+).
    #
    # CloudGPU is a plain OpenAI-compatible API: requests, responses and
    # transforms are identical to the OpenAI Chat API, so this provider
    # reuses OpenAI::Chat::RequestType and OpenAI::Chat::Transforms directly.
    # The only CloudGPU-specific configuration is the base URL and API key,
    # which live in CloudGPU::Options.
    #
    # @example Configuration in active_agent.yml
    #   cloudgpu:
    #     service: "CloudGPU"
    #     api_key: <%= ENV["CLOUDGPU_API_KEY"] %>
    #     model: "deepseek-v4-flash"
    #
    # @see OpenAI::ChatProvider
    # @see https://cloudgpu.app
    class CloudGPUProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "CloudGPU"
      end

      # @return [Class]
      def self.options_klass
        CloudGPU::Options
      end

      # @return [ActiveModel::Type::Value]
      def self.prompt_request_type
        OpenAI::Chat::RequestType.new
      end

      protected

      # @see BaseProvider#api_response_normalize
      # @param api_response [OpenAI::Models::ChatCompletion]
      # @return [Hash] normalized response hash
      def api_response_normalize(api_response)
        return api_response unless api_response

        OpenAI::Chat::Transforms.gem_to_hash(api_response)
      end
    end
  end
end
