require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "ollama/_types"

module ActiveAgent
  module Providers
    # Connects to local Ollama instances via OpenAI-compatible API.
    #
    # Provides chat completion and embedding functionality through locally-hosted
    # Ollama models. Handles connection errors specific to local deployments.
    #
    # @see OpenAI::ChatProvider
    class OllamaProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "Ollama"
      end

      # @return [Class]
      def self.options_klass
        namespace::Options
      end

      # @return [ActiveModel::Type::Value]
      def self.prompt_request_type
        namespace::Chat::RequestType.new
      end

      # @return [ActiveModel::Type::Value]
      def self.embed_request_type
        namespace::Embedding::RequestType.new
      end

      protected

      # Executes chat completion request with Ollama-specific error handling.
      #
      # @see OpenAI::ChatProvider#api_prompt_execute
      # @param parameters [Hash]
      # @return [Object, nil] response object or nil for streaming
      # @raise [OpenAI::Errors::APIConnectionError] when Ollama server unreachable
      def api_prompt_execute(parameters)
        super

      rescue ::OpenAI::Errors::APIConnectionError => exception
        log_connection_error(exception)
        raise exception
      end

      # Executes embedding request with Ollama-specific error handling.
      #
      # @param parameters [Hash]
      # @return [Hash] symbolized API response
      # @raise [OpenAI::Errors::APIConnectionError] when Ollama server unreachable
      def api_embed_execute(parameters)
        instrument("embeddings_request.provider.active_agent")
        client.embeddings.create(**parameters).as_json.deep_symbolize_keys

      rescue ::OpenAI::Errors::APIConnectionError => exception
        log_connection_error(exception)
        raise exception
      end

      # Handles role duplication bug in Ollama's OpenAI-compatible streaming.
      #
      # Ollama duplicates role information in streaming deltas, requiring
      # manual cleanup to prevent message corruption. This fixes the
      # "role appears in every chunk" issue when using streaming responses.
      #
      # @see OpenAI::ChatProvider#message_merge_delta
      # @param message [Hash]
      # @param delta [Hash]
      # @return [Hash]
      def message_merge_delta(message, delta)
        message[:role] = delta.delete(:role) if delta[:role] # Copy a Bad Design (OpenAI's Chat API) Badly, Win Bad Prizes

        hash_merge_delta(message, delta)
      end

      # Logs connection failures with Ollama server details for debugging.
      #
      # @param error [Exception]
      # @return [void]
      def log_connection_error(error)
        instrument("connection_error.provider.active_agent",
                  uri_base: options.uri_base,
                  exception: error.class,
                  message: error.message)
      end
    end
  end
end
