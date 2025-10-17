require_relative "concerns/error_handling"

require_relative "../action_prompt/action"
require_relative "response"

GEM_LOADERS = {
  anthropic: [ "anthropic",   "~> 1.12", "anthropic" ],
  openai:    [ "ruby-openai", "~> 8.3",  "openai" ],
  openssl:   [ "openssl",     "~> 3.3",  "openssl" ]
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
  module Providers
    class BaseProvider
      include ErrorHandling

      class ProvidersError < StandardError; end

      attr_internal :options, :context,                 # Setup
                    :request, :message_stack,           # Runtime
                    :stream_callback, :stream_finished, # Callback (Streams)
                    :function_callback                  # Callback (Tools)

      def self.to_sym
        fail(NotImplementedError, "Subclasses must implement the 'to_sym' method for reflection")
      end

      # Initializes the OpenAI provider with configuration options.
      #
      # Since we are routing between two different API versions that may/will have different
      # available options, we keep them as untyped hashes until generation which will route
      # to the appropriate provider implementation.
      #
      # @param options [Hash] Configuration options for the provider
      # @option options [Symbol] :api_version Force a specific API version (:chat or :responses)
      # @option options [Hash] :audio Audio configuration options
      #
      # @raise [RuntimeError] if the service name doesn't match the provider's service name
      def initialize(kwargs = {})
        assert_service!(kwargs.delete(:service))

        self.stream_callback   = kwargs.delete(:stream_callback)
        self.function_callback = kwargs.delete(:function_callback)
        self.options           = options_klass.new(kwargs.extract!(*options_klass.keys))
        self.context           = kwargs
        self.request           = request_klass.new(context)
        self.message_stack     = []
      end

      # Main entry point for executing the provider call.
      #
      # This method orchestrates the provider execution by wrapping the prompt
      # resolution in error handling logic. It serves as the primary interface
      # for initiating provider operations.
      #
      # @return [ActiveAgent::Providers::Response] The result of the prompt resolution
      # @raise [StandardError] Any errors that occur during execution will be
      #   handled by the error handling wrapper
      #
      # @example Execute the provider call
      #   provider.call
      #   # => <result of prompt resolution>
      def call
        with_error_handling do
          resolve_prompt
        end
      end

      # Optional embedding support - override in providers that support it
      # def embed(prompt)
      #   raise NotImplementedError, "#{self.class.name} does not support embeddings"
      # end

      # @return [String] Name of service, e.g., Anthropic
      def service_name
        self.class.name.split("::").last.delete_suffix("Provider")
      end

      # @return [Module] Module of Provider, e.g., ActiveAgent::Providers::OpenAI
      def namespace
        "#{self.class.name.deconstantize}::#{service_name}".safe_constantize
      end

      # @return [Class] Class of Provider Options, e.g., ActiveAgent::Providers::OpenAI::Options
      def options_klass = namespace::Options
      def request_klass = namespace::Request

      protected

      # @return response [ActiveAgent::Providers::Response]
      def resolve_prompt
        request = prepare_request_iteration

        # @todo Validate Request
        api_parameters = api_request_build(request)
        api_response   = api_prompt_execute(api_parameters)

        process_finished(api_response)
      end

      # Apply Tool/Function Messages and Reset Processing Buffer
      def prepare_request_iteration
        self.request.messages = [ *request.messages, *message_stack ]
        self.message_stack    = []

        self.request
      end

      # @abstract
      def api_prompt_execute(request_parameters)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # @abstract
      # @return void
      def process_stream_chunk(api_response_chunk)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # @abstract
      # MUST Handle Tool/Function Calls
      # @return response [ActiveAgent::Providers::Response]
      def process_finished(api_response = nil)
        fail NotImplementedError, "Subclass expected to implement"
      end

      private

      # @return [Hash]
      def api_request_build(request)
        parameters = request.to_hc
        return parameters unless request.stream

        self.stream_finished = false
        parameters[:stream]  = process_stream
        parameters
      end

      # @return [Proc] a Proc that accepts an API response chunk and processes it
      # @see #process_stream_chunk
      #
      # @example
      #   stream_processor = process_stream
      #   api_client.stream(params, &stream_processor)
      def process_stream
        proc do |api_response_chunk|
          process_stream_chunk(api_response_chunk)
        end
      end

      def assert_service!(name)
        fail "Unexpected Service Name: #{name} != #{service_name}" if name && name != service_name
      end
    end
  end
end
