require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "standard_compute/_types"

module ActiveAgent
  module Providers
    # Provides access to Standard Compute's OpenAI-compatible LLM gateway.
    #
    # Extends the OpenAI provider to work with Standard Compute's
    # OpenAI-compatible API. The default model +StandardCompute+ is routed:
    # each request goes to the cheapest enabled model that can handle it,
    # with automatic fallback. To pin a model, use an id from the public
    # +GET /v1/models+ list (e.g. +deepseek/deepseek-v4.1-flash+).
    #
    # Standard Compute is a plain OpenAI-compatible gateway: requests,
    # responses and transforms are identical to the OpenAI Chat API, so this
    # provider reuses OpenAI::Chat::RequestType and OpenAI::Chat::Transforms
    # directly. The only Standard Compute-specific configuration is the base
    # URL and API key, which live in StandardCompute::Options.
    #
    # @example Configuration in active_agent.yml
    #   standard_compute:
    #     service: "StandardCompute"
    #     api_key: <%= ENV["STANDARDCOMPUTE_API_KEY"] %>
    #     model: "StandardCompute"
    #
    # @see OpenAI::ChatProvider
    # @see https://standardcompute.com
    class StandardComputeProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "StandardCompute"
      end

      # @return [Class]
      def self.options_klass
        StandardCompute::Options
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
