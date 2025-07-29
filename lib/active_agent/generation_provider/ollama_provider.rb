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
        @client = OpenAI::Client.new(uri_base: @host, access_token: @access_token, log_errors: true)
      end
    end
  end
end
