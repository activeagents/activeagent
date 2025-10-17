require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "ollama/options"
require_relative "ollama/chat/request"
require_relative "ollama/embedding/request"

module ActiveAgent
  module Providers
    class OllamaProvider < OpenAI::ChatProvider
      # Overloads the OpenAI ChatProvider to use Ollama-specific options and defaults.
      def service_name         = "Ollama"
      def options_klass        = namespace::Options
      def prompt_request_klass = namespace::Chat::Request
      def embed_request_klass  = namespace::Embedding::Request

      protected

      def api_embed_execute(parameters)
        client.embeddings(parameters:)
      end

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

      # def embeddings_response(response, request_params = nil)
      #   # Ollama can return either format:
      #   # 1. OpenAI-compatible: { "data": [{ "embedding": [...] }] }
      #   # 2. Native Ollama: { "embedding": [...] }
      #   embedding = response.dig("data", 0, "embedding") || response.dig("embedding")

      #   message = ActiveAgent::ActionPrompt::Message.new(content: embedding, role: "assistant")

      #   @response = ActiveAgent::Providers::Response.new(
      #     prompt: prompt,
      #     message: message,
      #     raw_response: response,
      #     raw_request: request_params
      #   )
      # end
    end
  end
end
