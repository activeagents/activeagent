# lib/active_agent/generation_provider/base.rb

require_relative "error_handling"
require_relative "parameter_builder"

module ActiveAgent
  module GenerationProvider
    class Base
      include ErrorHandling
      include ParameterBuilder

      class GenerationProviderError < StandardError; end

      attr_reader :client, :config, :prompt, :response, :access_token, :model_name

      def initialize(config)
        @config = config
        @prompt = nil
        @response = nil
        @model_name = config["model"] if config
      end

      def generate(prompt)
        raise NotImplementedError, "Subclasses must implement the 'generate' method"
      end

      def embed(prompt)
        # Optional embedding support - override in providers that support it
        raise NotImplementedError, "#{self.class.name} does not support embeddings"
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

      # This method is now provided by ParameterBuilder module
      # but can still be overridden if needed
      def build_provider_parameters
        # Base implementation returns empty hash
        # Providers override this to add their specific parameters
        {}
      end
    end
  end
end
