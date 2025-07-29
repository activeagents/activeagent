# lib/active_agent/generation_provider/base.rb

module ActiveAgent
  module GenerationProvider
    class Base
      class GenerationProviderError < StandardError; end
      attr_reader :client, :config, :prompt, :response, :access_token, :model_name

      def initialize(config)
        @config = config
        @prompt = nil
        @response = nil
      end

      def generate(prompt)
        raise NotImplementedError, "Subclasses must implement the 'generate' method"
      end

      private

      def handle_response(response)
        @response = ActiveAgent::GenerationProvider::Response.new(message:, raw_response: response)
        raise NotImplementedError, "Subclasses must implement the 'handle_response' method"
      end

      def update_context(prompt:, message:, response:)
        prompt.message = message
        prompt.messages << message
      end

      protected

      def prompt_parameters
        {
          messages: @prompt.messages,
          temperature: @config["temperature"] || 0.7
        }
      end
    end
  end
end
