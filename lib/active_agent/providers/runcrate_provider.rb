require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "runcrate/_types"

module ActiveAgent
  module Providers
    # Provides access to Runcrate's OpenAI-compatible inference API for
    # open-weight models.
    #
    # Extends the OpenAI provider to work with Runcrate's OpenAI-compatible
    # API. Model ids are the vendor-prefixed names Runcrate lists at
    # +/v1/models+ (e.g. +deepseek-ai/DeepSeek-V4.1-Flash+).
    #
    # Runcrate is a plain OpenAI-compatible API: requests, responses and
    # transforms are identical to the OpenAI Chat API, so this provider
    # reuses OpenAI::Chat::RequestType and OpenAI::Chat::Transforms directly.
    # The only Runcrate-specific configuration is the base URL and API key,
    # which live in Runcrate::Options.
    #
    # @example Configuration in active_agent.yml
    #   runcrate:
    #     service: "Runcrate"
    #     api_key: <%= ENV["RUNCRATE_API_KEY"] %>
    #     model: "deepseek-ai/DeepSeek-V4.1-Flash"
    #
    # @see OpenAI::ChatProvider
    # @see https://runcrate.ai/docs/models/overview
    class RuncrateProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "Runcrate"
      end

      # @return [Class]
      def self.options_klass
        Runcrate::Options
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

      # Executes an embedding request via Runcrate's OpenAI-compatible API.
      #
      # @param parameters [Hash]
      # @return [Hash] symbolized API response
      def api_embed_execute(parameters)
        client.embeddings.create(**parameters).as_json.deep_symbolize_keys
      end

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
