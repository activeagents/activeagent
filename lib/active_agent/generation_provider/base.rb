# lib/active_agent/generation_provider/base.rb

module ActiveAgent
  module GenerationProvider
    class Base
      class GenerationProviderError < StandardError; end
      attr_reader :client, :config, :prompt

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
        ActiveAgent::GenerationProvider::Response.new(message:, raw_response: response)
        raise NotImplementedError, "Subclasses must implement the 'handle_response' method"
      end

      protected

      def prompt_parameters
        {
          messages: @prompt.messages,
          temperature: @config["temperature"] || 0.7
        }
      end

      def logger
        @logger ||= Logger.new($stdout)
      end

      private

      def extract_message_from_response(response)
        raise NotImplementedError, "Subclasses must implement the 'extract_message_from_response' method"
      end

      def handle_error(error)
        logger.error("#{self.class.name} Error: #{error.message}")
        raise error
      end
    end
  end
end
