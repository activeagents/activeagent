require_relative "concerns/error_handling"

require_relative "../action_prompt/action"
require_relative "response"

GEM_LOADERS = {
  anthropic: [ "anthropic",   "~> 1.12", "anthropic" ],
  openai:    [ "ruby-openai", "~> 8.3",  "openai" ]
}

# Dynamically requires a gem needed for a specific provider.
#
# This method ensures that the required gem is loaded with the correct version
# before attempting to use a provider. It will raise an informative error if
# the gem is not available.
#
# @param type [Symbol] The provider type (e.g., :anthropic, :openai)
# @param file_name [String] The file name of the provider being loaded
# @return [void]
# @raise [LoadError] if the required gem is not available in the bundle
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

      # Initializes the provider with configuration options.
      #
      # @param kwargs [Hash] Configuration options for the provider
      # @option kwargs [Symbol] :service The service name to validate against
      # @option kwargs [Proc] :stream_callback Callback for processing streaming responses
      # @option kwargs [Proc] :function_callback Callback for handling tool/function calls
      # @return [void]
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

      # Returns the name of the service this provider represents.
      #
      # Extracts the service name from the class name by removing the "Provider" suffix.
      # For example, "AnthropicProvider" becomes "Anthropic".
      #
      # @return [String] Name of service (e.g., "Anthropic", "OpenAI")
      def service_name
        self.class.name.split("::").last.delete_suffix("Provider")
      end

      # Returns the namespace module for this provider.
      #
      # Constructs and constantizes the full module path for the provider.
      # For example, returns `ActiveAgent::Providers::OpenAI` module.
      #
      # @return [Module] Module of Provider (e.g., ActiveAgent::Providers::OpenAI)
      def namespace
        "#{self.class.name.deconstantize}::#{service_name}".safe_constantize
      end

      # Returns the Options class for this provider.
      #
      # @return [Class] Class of Provider Options (e.g., ActiveAgent::Providers::OpenAI::Options)
      def options_klass = namespace::Options

      # Returns the Request class for this provider.
      #
      # @return [Class] Class of Provider Request (e.g., ActiveAgent::Providers::OpenAI::Request)
      def request_klass = namespace::Request

      protected

      # Resolves the prompt by executing the full request cycle.
      #
      # This method orchestrates the complete prompt resolution process: preparing the
      # request iteration, building API parameters, executing the prompt, and processing
      # the finished response. It handles tool/function calls recursively if needed.
      #
      # @return [ActiveAgent::Providers::Response] The final response after processing
      def resolve_prompt
        request = prepare_request_iteration

        # @todo Validate Request
        api_parameters = api_request_build(request)
        api_response   = api_prompt_execute(api_parameters)

        process_finished(api_response)
      end

      # Prepares the request for the next iteration.
      #
      # Applies any tool/function messages from the message stack to the request
      # and resets the processing buffer for the next iteration. This is essential
      # for multi-turn conversations and tool calling.
      #
      # @return [Request] The updated request object
      def prepare_request_iteration
        self.request.messages = [ *request.messages, *message_stack ]
        self.message_stack    = []

        self.request
      end

      # Executes the API request to the provider.
      #
      # This is an abstract method that must be implemented by subclasses to handle
      # the actual API call to their specific service (e.g., OpenAI, Anthropic).
      #
      # @abstract Subclasses must implement this method
      # @param request_parameters [Hash] The parameters to send to the API
      # @return [Object] The API response object (format varies by provider)
      # @raise [NotImplementedError] if called on a subclass that hasn't implemented it
      def api_prompt_execute(request_parameters)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Processes a single chunk from a streaming API response.
      #
      # This is an abstract method that must be implemented by subclasses to handle
      # streaming response chunks from their specific service. The implementation
      # should extract relevant data and invoke the stream callback if provided.
      #
      # @abstract Subclasses must implement this method
      # @param api_response_chunk [Object] A single chunk from the streaming response
      # @return [void]
      # @raise [NotImplementedError] if called on a subclass that hasn't implemented it
      def process_stream_chunk(api_response_chunk)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Processes the finished API response and handles tool/function calls.
      #
      # This method extracts messages and function calls from the API response.
      # If function calls are present, it processes them and recursively resolves
      # the prompt again. Otherwise, it returns a final Response object. This is
      # the core method that enables multi-turn tool calling.
      #
      # @param api_response [Object, nil] The completed API response object
      # @return [ActiveAgent::Providers::Response] The final response or recursive result
      def process_finished(api_response = nil)
        if (api_messages = process_finished_extract_messages(api_response))
          message_stack.push(*api_messages)
        end

        if (tool_calls = process_finished_extract_function_calls)&.any?
          process_function_calls(tool_calls)
          resolve_prompt
        else
          ActiveAgent::Providers::Response.new(
            prompt: context,
            message: message_stack.last,
            raw_request: request,
            raw_response: api_response
          )
        end
      end

      # Extracts messages from the finished API response.
      #
      # This is an abstract method that must be implemented by subclasses to parse
      # messages from their provider's response format.
      #
      # @abstract Subclasses must implement this method
      # @param api_response [Object] The API response object to extract messages from
      # @return [Array<Message>, nil] Array of message objects or nil if none present
      # @raise [NotImplementedError] if called on a subclass that hasn't implemented it
      def process_finished_extract_messages(api_response)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Extracts function/tool calls from the finished API response.
      #
      # This is an abstract method that must be implemented by subclasses to parse
      # function calls from their provider's response format.
      #
      # @abstract Subclasses must implement this method
      # @return [Array<Hash>, nil] Array of function call hashes or nil if none present
      # @raise [NotImplementedError] if called on a subclass that hasn't implemented it
      def process_finished_extract_function_calls
        fail NotImplementedError, "Subclass expected to implement"
      end

      private

      # Validates that the service name matches the expected provider.
      #
      # This is a safety check to ensure that the correct provider is being used
      # for the specified service name.
      #
      # @param name [String, nil] The service name to validate
      # @return [void]
      # @raise [RuntimeError] if the service name doesn't match the provider's service name
      def assert_service!(name)
        fail "Unexpected Service Name: #{name} != #{service_name}" if name && name != service_name
      end

      # Builds the API request parameters from the request object.
      #
      # Converts the request to a hash and configures streaming if enabled.
      # When streaming is enabled, sets up the stream processor and marks
      # streaming as not yet finished.
      #
      # @param request [Request] The request object to convert to API parameters
      # @return [Hash] The API request parameters ready to send
      def api_request_build(request)
        parameters = request.to_hc
        return parameters unless request.stream

        self.stream_finished = false
        parameters[:stream]  = process_stream
        parameters
      end

      # Returns a Proc that processes streaming API response chunks.
      #
      # Creates a Proc that can be passed to the API client as a streaming callback.
      # Each chunk received will be processed by the {#process_stream_chunk} method.
      #
      # @return [Proc] A Proc that accepts an API response chunk and processes it
      # @see #process_stream_chunk
      # @example
      #   stream_processor = process_stream
      #   api_client.stream(params, &stream_processor)
      def process_stream
        proc do |api_response_chunk|
          process_stream_chunk(api_response_chunk)
        end
      end
    end
  end
end
