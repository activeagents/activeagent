require "openai"
require_relative "open_ai_provider"
require_relative "openai_adapters/chat_completions_adapter"
require_relative "openai_adapters/responses_adapter"

module ActiveAgent
  module GenerationProvider
    class OllamaProvider < OpenAIProvider
      def initialize(config)
        # Let parent handle most initialization
        super(config)
        
        # Override client for Ollama-specific settings
        @host = config["host"] || "http://localhost:11434"
        @client = OpenAI::Client.new(uri_base: @host, access_token: @api_key, log_errors: true)
        
        # Re-initialize adapters with the new client
        @chat_adapter = OpenAIAdapters::ChatCompletionsAdapter.new(@client, @config)
        @responses_adapter = OpenAIAdapters::ResponsesAdapter.new(@client, @config)
      end
    end
  end
end
