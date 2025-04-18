require "openai"
require_relative "open_ai_provider"

module ActiveAgent
  module GenerationProvider
    class OpenRouterProvider < OpenAIProvider
      def initialize(config)
        @config = config
        @api_key = config["api_key"]
        @model_name = config["model"]
        @client = OpenAI::Client.new(uri_base: "https://openrouter.ai/api/v1", access_token: @api_key, log_errors: true)
      end
    end
  end
end
