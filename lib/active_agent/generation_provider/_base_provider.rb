require_relative "concerns/error_handling"
require_relative "concerns/message_formatting"
require_relative "concerns/parameter_builder"
require_relative "concerns/stream_processing"
require_relative "concerns/tool_management"

require_relative "../action_prompt/action"
require_relative "response"
require_relative "responses_adapter"

GEM_LOADERS = {
  anthropic: [ "ruby-anthropic", "~> 0.4.2", "anthropic" ],
  openai:    [ "ruby-openai", ">= 8.1.0", "openai" ]
}

def require_gem!(type, file_name)
  gem_name, requirement, package_name = GEM_LOADERS.fetch(type)
  provider_name = file_name.split("/").last.delete_suffix(".rb").camelize

  begin
    gem(gem_name, requirement)
    require(package_name)
  rescue LoadError
    raise LoadError, "The '#{gem_name}' gem is required for #{provider_name}. Please add it to your Gemfile and run `bundle install`."
  end
end

module ActiveAgent
  module GenerationProvider
    class BaseProvider
      include ErrorHandling
      include ParameterBuilder

      class GenerationProviderError < StandardError; end

      attr_reader :options
      attr_reader :config, :prompt, :response, :model_name

      def initialize(config)
        @config     = config
        @prompt     = nil
        @response   = nil
        @model_name = config["model"] if config
      end

      def generate(prompt)
        raise NotImplementedError, "Subclasses must implement the 'generate' method"
      end

      # Optional embedding support - override in providers that support it
      def embed(prompt)
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
