require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "ollama/options"

module ActiveAgent
  module GenerationProvider
    class OllamaProvider < OpenAIProvider

      def initialize(config)
        @api_version     = config.delete("api_version") || "v1"
        @embedding_model = config.delete("embedding_model")
        super
      end

      protected

      def namespace = Ollama

      def format_error_message(error)
        # Check for various connection-related errors
        connection_errors = [
          Errno::ECONNREFUSED,
          Errno::EADDRNOTAVAIL,
          Errno::EHOSTUNREACH,
          Net::OpenTimeout,
          Net::ReadTimeout,
          SocketError,
          Faraday::ConnectionFailed
        ]

        if connection_errors.any? { |klass| error.is_a?(klass) } ||
            (error.message&.include?("Failed to open TCP connection") ||
             error.message&.include?("Connection refused"))
          "Unable to connect to Ollama at #{@options.uri_base}. Please ensure Ollama is running on the configured host and port.\n" \
          "You can start Ollama with: `ollama serve`\n" \
          "Or update your configuration to point to the correct host."
        else
          super
        end
      end

      def embeddings_parameters(input: prompt.message.content, model: "nomic-embed-text")
        {
          model: @embedding_model || model,
          input: input
        }
      end

      def embeddings_response(response, request_params = nil)
        # Ollama can return either format:
        # 1. OpenAI-compatible: { "data": [{ "embedding": [...] }] }
        # 2. Native Ollama: { "embedding": [...] }
        embedding = response.dig("data", 0, "embedding") || response.dig("embedding")

        message = ActiveAgent::ActionPrompt::Message.new(content: embedding, role: "assistant")

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: message,
          raw_response: response,
          raw_request: request_params
        )
      end
    end
  end
end
