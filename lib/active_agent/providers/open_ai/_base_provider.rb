require_relative "../_base_provider"

require_gem!(:openai, __FILE__)

require_relative "options"

module ActiveAgent
  module Providers
    module OpenAI
      # Base provider implementation for OpenAI API integration.
      #
      # This class serves as the foundation for OpenAI-based providers, handling
      # message management, streaming responses, and function/tool callbacks.
      #
      # @abstract Subclass and override {#client_request_create} to implement specific provider behavior
      #
      # @example Basic usage
      #   provider = BaseProvider.new(
      #     stream_callback: ->(chunk) { puts chunk },
      #     function_callback: ->(name, **kwargs) { execute_function(name, kwargs) }
      #   )
      #   response = provider.call
      #
      # @attr_internal request [ActiveAgent::Request] The current request being processed
      # @attr_internal message_stack [Array] Stack of messages to be applied to the request
      # @attr_internal stream_callback [Proc] Callback invoked for each streaming chunk
      # @attr_internal stream_finished [Boolean] Flag indicating if streaming has completed
      # @attr_internal function_callback [Proc] Callback for handling function/tool calls
      #
      # @see ActiveAgent::Providers::BaseProvider
      class BaseProvider < ActiveAgent::Providers::BaseProvider
        attr_internal :request, :message_stack,
                      :stream_callback, :stream_finished,
                      :function_callback

        def initialize(kwargs = {})
          self.stream_callback   = kwargs.delete(:stream_callback)
          self.function_callback = kwargs.delete(:function_callback)
          self.message_stack     = []

          super(kwargs)

          self.request = request_klass.new(context)
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

        # @return [OpenAI::Client] a configured OpenAI client instance
        def client
          ::OpenAI::Client.new(options.to_hc)
        end

        # @return [String] Name of service, e.g., Anthropic
        def service_name = "OpenAI"

        protected

        def namespace     = "#{self.class.name.deconstantize}::#{service_name}".safe_constantize
        def options_klass = namespace::Options
        def request_klass = namespace::Request

        # @return response [ActiveAgent::Providers::Response]
        def resolve_prompt
          # Apply Tool/Function Messages and Reset Processing Buffer
          self.request.messages = [ *request.messages, *message_stack ]
          self.message_stack    = []
          # @todo Validate Request

          ## Prepare Executation Environment
          parameters = request.to_hc
          if request.stream
            parameters[:stream]  = process_stream
            self.stream_finished = false
          end

          ## Execute
          api_response = client_request_create(parameters:)
          process_finished(api_response.presence&.deep_symbolize_keys)
        end

        def client_request_create(parameters:)
          fail(NotImplementedError)
        end

        # @return [Proc] a Proc that accepts an API response chunk and processes it
        # @see #process_stream_chunk
        #
        # @example
        #   stream_processor = process_stream
        #   api_client.stream(params, &stream_processor)
        def process_stream
          proc do |api_response_chunk|
            process_stream_chunk(api_response_chunk.deep_symbolize_keys)
          end
        end

        # Processes a tool call function from the API response.
        #
        # This method extracts the function name and arguments from an API function call,
        # parses the arguments as JSON, and invokes the function callback with the parsed parameters.
        #
        # @param api_function_call [Hash] The function call data from the API response
        # @option api_function_call [String] :name The name of the function to call
        # @option api_function_call [String] :arguments JSON string containing the function arguments
        #
        # @return [Object] The result of the function callback invocation
        #
        # @example Processing a tool call
        #   api_call = { name: "get_weather", arguments: '{"location":"NYC"}' }
        #   process_tool_call_function(api_call)
        #   # => calls function_callback.call("get_weather", location: "NYC")
        def process_tool_call_function(api_function_call)
          name   = api_function_call[:name]
          kwargs = JSON.parse(api_function_call[:arguments], symbolize_names: true) if api_function_call[:arguments]

          function_callback.call(name, **kwargs)
        end
      end
    end
  end
end
