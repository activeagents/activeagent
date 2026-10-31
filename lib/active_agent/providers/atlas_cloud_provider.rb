# frozen_string_literal: true

require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "atlas_cloud/options"

module ActiveAgent
  module Providers
    # Provides access to Atlas Cloud's OpenAI-compatible Chat Completions API.
    #
    # Atlas Cloud uses provider/model identifiers such as +qwen/qwen3.8-max+.
    # Request and response handling is shared with the OpenAI Chat provider;
    # only the endpoint and API-key resolution are provider-specific.
    class AtlasCloudProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "AtlasCloud"
      end

      # @return [Class]
      def self.options_klass
        AtlasCloud::Options
      end

      # @return [ActiveModel::Type::Value]
      def self.prompt_request_type
        OpenAI::Chat::RequestType.new
      end

      protected

      # @see BaseProvider#api_response_normalize
      # @param api_response [OpenAI::Models::ChatCompletion]
      # @return [Hash]
      def api_response_normalize(api_response)
        return api_response unless api_response

        OpenAI::Chat::Transforms.gem_to_hash(api_response)
      end
    end
  end
end
