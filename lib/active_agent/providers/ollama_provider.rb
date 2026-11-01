require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "ollama/_types"

module ActiveAgent
  module Providers
    # Connects to Ollama through its OpenAI-compatible API: a local server,
    # a remote one, or Ollama Cloud (https://ollama.com).
    #
    # Provides chat completion and embedding functionality, and lists and
    # describes the models the host serves ({#models}, {#model_info}).
    # Handles connection errors specific to local deployments, and asks for
    # an API key before a request to the cloud that would be refused
    # without one.
    #
    # @example A local server
    #   generate_with :ollama, model: "qwen3:8b"
    #
    # @example Ollama Cloud, the key from OLLAMA_API_KEY
    #   generate_with :ollama, cloud: true, model: "gpt-oss:120b"
    #
    # @see OpenAI::ChatProvider
    # @see Ollama::Options
    # @see Ollama::Cloud
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

      # @return [Boolean] whether requests go to Ollama Cloud
      def cloud?
        options.cloud?
      end

      # The models the configured host serves, from the host's own API.
      #
      # @return [Ollama::Catalog]
      def catalog
        namespace::Catalog.new(host: options.base_url, api_key: options.api_key)
      end

      # Lists the models the configured host serves.
      #
      # @return [Array<Ollama::Catalog::Model>]
      # @raise [Ollama::Catalog::Error] when the host cannot be read
      def models
        catalog.models
      end

      # Describes one model the configured host serves: its details,
      # capabilities and context length.
      #
      # @param name [String]
      # @return [Ollama::Catalog::Model]
      # @raise [Ollama::Catalog::NotFoundError] when the host does not serve it
      # @raise [Ollama::Catalog::Error] when the host cannot be read
      def model_info(name)
        catalog.model_info(name)
      end

      # The OpenAI client, once the cloud's key requirement is met.
      #
      # @see OpenAI::Base#client
      # @raise [Errors::AuthenticationFailed] on the cloud host without a key
      def client
        options.require_cloud_api_key!
        super
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
