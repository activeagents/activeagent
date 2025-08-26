require "openai"
require_relative "open_ai_provider"

module ActiveAgent
  module GenerationProvider
    class OllamaProvider < OpenAIProvider
      def initialize(config)
        @config = config
        @access_token ||= config["api_key"] || config["access_token"] || ENV["OLLAMA_API_KEY"] || ENV["OLLAMA_ACCESS_TOKEN"]
        @model_name = config["model"]
        @host = config["host"] || "http://localhost:11434"
        @api_version = config["api_version"] || "v1"
        @client = OpenAI::Client.new(uri_base: @host, access_token: @access_token, log_errors: Rails.env.development?, api_version: @api_version)
      end

      protected

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
          "Unable to connect to Ollama at #{@host}. Please ensure Ollama is running on the configured host and port.\n" \
          "You can start Ollama with: `ollama serve`\n" \
          "Or update your configuration to point to the correct host."
        else
          super
        end
      end

      def embeddings_parameters(input: prompt.message.content, model: "nomic-embed-text")
        {
          model: @config["embedding_model"] || model,
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
