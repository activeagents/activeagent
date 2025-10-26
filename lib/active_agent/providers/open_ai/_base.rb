require_relative "../_base_provider"

require_gem!(:openai, __FILE__)

require_relative "options"

module ActiveAgent
  module Providers
    module OpenAI
      # Base provider class for OpenAI API implementations.
      #
      # Provides common functionality for OpenAI-based providers including
      # client configuration, service identification, and tool call processing.
      #
      # @see ActiveAgent::Providers::BaseProvider
      class Base < ActiveAgent::Providers::BaseProvider
        # Returns a configured OpenAI client instance.
        #
        # @return [OpenAI::Client] The configured OpenAI client
        def client
          ::OpenAI::Client.new(**options.serialize)
        end

        # Returns the service name for OpenAI providers.
        #
        # @return [String] Always returns "OpenAI"
        def service_name = "OpenAI"

        protected

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
        #   # => calls tools_function.call("get_weather", location: "NYC")
        def process_tool_call_function(api_function_call)
          name   = api_function_call[:name]
          kwargs = JSON.parse(api_function_call[:arguments], symbolize_names: true) if api_function_call[:arguments]

          instrument("tool_execution.provider.active_agent", tool_name: name)
          tools_function.call(name, **kwargs)
        end
      end
    end
  end
end
