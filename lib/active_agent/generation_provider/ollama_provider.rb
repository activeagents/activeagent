require "openai"
require_relative "open_ai_provider"

module ActiveAgent
  module GenerationProvider
    class OllamaProvider < OpenAIProvider
      def initialize(config)
        @config = config
        @api_key = config["api_key"]
        @model_name = config["model"]
        @host = config["host"] || "http://localhost:11434"
        @client = OpenAI::Client.new(uri_base: @host, access_token: @api_key, log_errors: true)
      end
    end
  end
end
