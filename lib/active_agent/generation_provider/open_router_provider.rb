require "openai"
require_relative "open_ai_provider"

module ActiveAgent
  module GenerationProvider
    class OpenRouterProvider < OpenAIProvider
      def initialize(config)
        @config = config
        @access_token ||= config["api_key"] || config["access_token"] || ENV["OPENROUTER_API_KEY"] || ENV["OPENROUTER_ACCESS_TOKEN"]
        @model_name = config["model"]
        @client = OpenAI::Client.new(uri_base: "https://openrouter.ai/api/v1", access_token: @access_token, log_errors: true)
      end
    end
  end
end
