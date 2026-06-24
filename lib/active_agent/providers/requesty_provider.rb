require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "requesty/_types"

module ActiveAgent
  module Providers
    # Provides access to Requesty's OpenAI-compatible LLM gateway.
    #
    # Extends the OpenAI provider to work with Requesty's OpenAI-compatible API,
    # enabling access to multiple AI models through a single interface using the
    # +provider/model+ naming convention (e.g. +openai/gpt-4o-mini+).
    #
    # Requesty is a plain OpenAI-compatible gateway: requests, responses and
    # transforms are identical to the OpenAI Chat API, so this provider reuses
    # OpenAI::Chat::RequestType and OpenAI::Chat::Transforms directly. The only
    # Requesty-specific configuration is the base URL and API key, which live in
    # Requesty::Options.
    #
    # @example Configuration in active_agent.yml
    #   requesty:
    #     service: "Requesty"
    #     api_key: <%= ENV["REQUESTY_API_KEY"] %>
    #     model: "openai/gpt-4o-mini"
    #
    # @see OpenAI::ChatProvider
    # @see https://docs.requesty.ai
    class RequestyProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "Requesty"
      end

      # @return [Class]
      def self.options_klass
        Requesty::Options
      end

      # @return [ActiveModel::Type::Value]
      def self.prompt_request_type
        OpenAI::Chat::RequestType.new
      end

      # @return [ActiveModel::Type::Value]
      def self.embed_request_type
        OpenAI::Embedding::RequestType.new
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
