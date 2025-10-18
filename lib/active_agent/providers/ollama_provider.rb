require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "ollama/options"
require_relative "ollama/chat/request"
require_relative "ollama/embedding/request"

module ActiveAgent
  module Providers
    # Provider implementation for Ollama local models.
    #
    # Extends OpenAI::ChatProvider to work with Ollama's OpenAI-compatible API.
    # Supports both chat completion and embeddings through local Ollama instances.
    #
    # @see OpenAI::ChatProvider
    class OllamaProvider < OpenAI::ChatProvider
      def service_name         = "Ollama"
      def options_klass        = namespace::Options
      def prompt_request_klass = namespace::Chat::Request
      def embed_request_klass  = namespace::Embedding::Request

      protected

      # Executes a prompt request via Ollama's API.
      #
      # @param parameters [Hash] The prompt request parameters
      # @return [Object] The prompt response from Ollama
      def api_prompt_execute(parameters)
        super

      rescue Faraday::ConnectionFailed => exception
        log_connection_error(exception)
        raise exception
      end

      # Executes an embedding request via Ollama's API.
      #
      # @param parameters [Hash] The embedding request parameters
      # @return [Object] The embedding response from Ollama
      def api_embed_execute(parameters)
        instrument("embeddings_request.provider.active_agent")
        client.embeddings(parameters:).deep_symbolize_keys

      rescue Faraday::ConnectionFailed => exception
        log_connection_error(exception)
        raise exception
      end

      # Merges streaming delta into the message.
      #
      # Handles Ollama's role copying behavior which mimics OpenAI's design.
      #
      # @param message [Hash] The current message being built
      # @param delta [Hash] The delta to merge into the message
      # @return [Hash] The merged message
      def message_merge_delta(message, delta)
        message[:role] = delta.delete(:role) if delta[:role] # Copy a Bad Design (OpenAI's Chat API) Badly, Win Bad Prizes

        hash_merge_delta(message, delta)
      end

      # Logs a connection error with helpful debugging information.
      #
      # @param error [Exception] The connection error that occurred
      def log_connection_error(error)
        instrument("connection_error.provider.active_agent",
                  uri_base: options.uri_base,
                  exception: error.class,
                  message: error.message)
      end
    end
  end
end
