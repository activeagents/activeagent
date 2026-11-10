require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "uber_llm/_types"

module ActiveAgent
  module Providers
    # Provides access to UberLLM's OpenAI-compatible API.
    #
    # Extends the OpenAI provider to work with UberLLM's OpenAI-compatible
    # API, which serves models from many vendors behind one key. Model ids are
    # the vendor-prefixed names UberLLM lists at +/v1/models+ (e.g.
    # +deepseek/deepseek-v4.1-flash+).
    #
    # UberLLM is a plain OpenAI-compatible API: requests, responses and
    # transforms are identical to the OpenAI Chat API, so this provider
    # reuses OpenAI::Chat::RequestType and OpenAI::Chat::Transforms directly.
    # The only UberLLM-specific configuration is the base URL and API key,
    # which live in UberLLM::Options. UberLLM serves no embedding models, so
    # embeddings are not supported.
    #
    # @example Configuration in active_agent.yml
    #   uber_llm:
    #     service: "UberLLM"
    #     api_key: <%= ENV["UBERLLM_API_KEY"] %>
    #     model: "deepseek/deepseek-v4.1-flash"
    #
    # @see OpenAI::ChatProvider
    # @see https://uberllm.dev/docs
    class UberLLMProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "UberLLM"
      end

      # @return [Class]
      def self.options_klass
        UberLLM::Options
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
