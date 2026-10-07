require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "opper/_types"

module ActiveAgent
  module Providers
    # Provides access to Opper's OpenAI-compatible LLM gateway.
    #
    # Extends the OpenAI provider to work with Opper's OpenAI-compatible API,
    # enabling access to models from many providers through a single
    # interface. Model ids are bare pool names (e.g. +claude-sonnet-4-6+);
    # a +provider/model+ id (e.g. +anthropic/claude-sonnet-4-6+) pins a route.
    #
    # Opper is a plain OpenAI-compatible gateway: requests, responses and
    # transforms are identical to the OpenAI Chat API, so this provider reuses
    # OpenAI::Chat::RequestType and OpenAI::Chat::Transforms directly. The only
    # Opper-specific configuration is the base URL and API key, which live in
    # Opper::Options.
    #
    # @example Configuration in active_agent.yml
    #   opper:
    #     service: "Opper"
    #     api_key: <%= ENV["OPPER_API_KEY"] %>
    #     model: "claude-sonnet-4-6"
    #
    # @see OpenAI::ChatProvider
    # @see https://docs.opper.ai
    class OpperProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "Opper"
      end

      # @return [Class]
      def self.options_klass
        Opper::Options
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
