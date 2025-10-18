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

      # Executes an embedding request via Ollama's API.
      #
      # @param parameters [Hash] The embedding request parameters
      # @return [Object] The embedding response from Ollama
      def api_embed_execute(parameters)
        client.embeddings(parameters:).deep_symbolize_keys
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

      # def format_error_message(error)
      #   # Check for various connection-related errors
      #   connection_errors = [
      #     Errno::ECONNREFUSED,
      #     Errno::EADDRNOTAVAIL,
      #     Errno::EHOSTUNREACH,
      #     Net::OpenTimeout,
      #     Net::ReadTimeout,
      #     SocketError,
      #     Faraday::ConnectionFailed
      #   ]

      #   if connection_errors.any? { |klass| error.is_a?(klass) } ||
      #       (error.message&.include?("Failed to open TCP connection") ||
      #        error.message&.include?("Connection refused"))
      #     "Unable to connect to Ollama at #{@options.uri_base}. Please ensure Ollama is running on the configured host and port.\n" \
      #     "You can start Ollama with: `ollama serve`\n" \
      #     "Or update your configuration to point to the correct host."
      #   else
      #     super
      #   end
      # end
    end
  end
end
