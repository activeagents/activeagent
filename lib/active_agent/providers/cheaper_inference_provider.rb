require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "cheaper_inference/_types"

module ActiveAgent
  module Providers
    # Provides access to Cheaper Inference's OpenAI-compatible LLM gateway.
    #
    # Extends the OpenAI provider to work with Cheaper Inference's
    # OpenAI-compatible API, enabling access to models from many providers
    # through a single interface. Model ids are bare names (e.g.
    # +gpt-5.4-mini+).
    #
    # Cheaper Inference is a plain OpenAI-compatible gateway: requests,
    # responses and transforms are identical to the OpenAI Chat API, so this
    # provider reuses OpenAI::Chat::RequestType and OpenAI::Chat::Transforms
    # directly. The only Cheaper Inference-specific configuration is the base
    # URL and API key, which live in CheaperInference::Options.
    #
    # @example Configuration in active_agent.yml
    #   cheaper_inference:
    #     service: "CheaperInference"
    #     api_key: <%= ENV["CHEAPER_INFERENCE_API_KEY"] %>
    #     model: "gpt-5.4-mini"
    #
    # @see OpenAI::ChatProvider
    # @see https://cheaperinference.com/docs
    class CheaperInferenceProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "CheaperInference"
      end

      # @return [Class]
      def self.options_klass
        CheaperInference::Options
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

      # Executes an embedding request via Cheaper Inference's OpenAI-compatible API.
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
