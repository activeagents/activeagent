require_relative "concerns/error_handling"
require_relative "concerns/message_formatting"
require_relative "concerns/parameter_builder"
require_relative "concerns/tool_management"

require_relative "../action_prompt/action"
require_relative "response"

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

      attr_internal :options

      def initialize(options = {})
        fail "Unexpected Service Name: #{options["service"]} != #{service_name}" if options["service"] && options["service"] != service_name

        self.options = options_type.new(**(options || {}).except("service"))
      end

      def generate(prompt)
        raise NotImplementedError, "Subclasses must implement the 'generate' method"
      end

      # Optional embedding support - override in providers that support it
      def embed(prompt)
        raise NotImplementedError, "#{self.class.name} does not support embeddings"
      end

      # @return [String] Name of service, e.g., Anthropic
      def service_name
        self.class.name.split("::").last.delete_suffix("Provider")
      end

      private

      # @return [Class] The Options class for the specific provider, e.g., Anthropic::Options
      def options_type
        self.class.module_parent.const_get("#{service_name}::Options", false)
      end

      def handle_response(response)
        raise NotImplementedError, "Subclasses must implement the 'handle_response' method"
      end

      def update_context(prompt:, message:, response:)
        prompt.message = message
        prompt.messages << message
      end
    end
  end
end
