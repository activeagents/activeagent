# lib/active_agent/generation_provider/base.rb

module ActiveAgent
  module GenerationProvider
    class Base
      class GenerationProviderError < StandardError; end
      attr_reader :client, :config, :prompt, :response

      def initialize(config, prompt: nil)
        @config = config
        @prompt = prompt
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
        params = {
          messages: @prompt.messages,
          temperature: @config["temperature"] || 0.7
        }

        # Basic response format support (provider-specific implementations should override)
        if @prompt.options[:response_format]
          params[:response_format] = @prompt.options[:response_format]
        elsif @config["response_format"]
          params[:response_format] = @config["response_format"]
        end

        params
      end
    end
  end
end
