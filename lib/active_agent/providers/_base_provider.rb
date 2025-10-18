require_relative "common/response"
require_relative "concerns/error_handling"

GEM_LOADERS = {
  anthropic: [ "anthropic",   "~> 1.12", "anthropic" ],
  openai:    [ "ruby-openai", "~> 8.3",  "openai" ]
}

# Loads a provider's required gem dependency.
#
# @param type [Symbol] provider type (:anthropic, :openai)
# @param file_name [String] provider file name
# @return [void]
# @raise [LoadError] if the gem is not available
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
    # Base class for all provider implementations.
    #
    # Handles provider initialization, request orchestration, streaming,
    # and tool/function calling. Subclasses must implement provider-specific
    # methods for API interaction.
    class BaseProvider
      include ErrorHandling

      class ProvidersError < StandardError; end

      attr_internal :options, :context,              # Setup
                    :request, :message_stack,        # Runtime
                    :stream_broadcaster, :streaming, # Callback (Streams)
                    :tools_function                  # Callback (Tools)

      # Initializes the provider.
      #
      # @param kwargs [Hash] configuration options
      # @option kwargs [Symbol] :service service name to validate
      # @option kwargs [Proc] :stream_broadcaster callback for streaming responses
      # @option kwargs [Proc] :tools_function callback for tool/function calls
      # @return [void]
      # @raise [RuntimeError] if service name doesn't match provider
      def initialize(kwargs = {})
        assert_service!(kwargs.delete(:service))

        self.stream_broadcaster = kwargs.delete(:stream_broadcaster)
        self.streaming          = false

        self.tools_function     = kwargs.delete(:tools_function)

        self.options            = options_klass.new(kwargs.extract!(*options_klass.keys))
        self.context            = kwargs
        self.message_stack      = []
      end

      # Executes the provider prompt with error handling.
      #
      # @return [ActiveAgent::Providers::Response] the prompt resolution result
      # @raise [StandardError] handled by error handling wrapper
      def prompt
        self.request = prompt_request_klass.new(context)

        with_error_handling do
          resolve_prompt
        end
      end

      # Executes the provider embedding request with error handling.
      #
      # Converts text input into vector embeddings for semantic search
      # and similarity comparisons.
      #
      # @return [ActiveAgent::Providers::Common::EmbedResponse] the embedding result
      # @raise [StandardError] handled by error handling wrapper
      def embed
        self.request = embed_request_klass.new(context)

        with_error_handling do
          resolve_embed
        end
      end

      # Returns the service name for this provider.
      #
      # @return [String] service name (e.g., "Anthropic", "OpenAI")
      def service_name
        self.class.name.split("::").last.delete_suffix("Provider")
      end

      # Returns the namespace module for this provider.
      #
      # @return [Module] provider module (e.g., ActiveAgent::Providers::OpenAI)
      def namespace
        "#{self.class.name.deconstantize}::#{service_name}".safe_constantize
      end

      # Returns the Options class for this provider.
      #
      # @return [Class] provider options class (e.g., ActiveAgent::Providers::OpenAI::Options)
      def options_klass = namespace::Options

      # Returns the Request class for this provider.
      #
      # @return [Class] provider request class (e.g., ActiveAgent::Providers::OpenAI::Request)
      def prompt_request_klass = namespace::Request

      # Returns the EmbedRequest class for this provider.
      #
      # @note Not all providers support embeddings
      # @return [Class] provider embed request class (e.g., ActiveAgent::Providers::OpenAI::EmbedRequest)
      # @raise [NotImplementedError] if embeddings not supported by provider
      def embed_request_klass = fail(NotImplementedError)

      protected

      # Validates the service name matches the provider.
      #
      # @param name [String, nil] service name to validate
      # @return [void]
      # @raise [RuntimeError] if service name mismatch
      def assert_service!(name)
        fail "Unexpected Service Name: #{name} != #{service_name}" if name && name != service_name
      end

      # Executes the complete prompt request cycle.
      #
      # Prepares the request, builds API parameters, executes the prompt,
      # and processes the response. Handles recursive tool/function calls
      # until no more tools are invoked.
      #
      # @return [ActiveAgent::Providers::Common::PromptResponse] final response
      def resolve_prompt
        request = prepare_prompt_request

        # @todo Validate Request
        api_parameters = api_request_build(request)
        api_response   = api_prompt_execute(api_parameters)

        process_prompt_finished(api_response)
      end

      # Executes the complete embedding request cycle.
      #
      # Builds API parameters, executes the embedding request,
      # and processes the response into a standardized format.
      #
      # @return [ActiveAgent::Providers::Common::EmbedResponse] embedding response
      def resolve_embed
        # @todo Validate Request
        api_parameters = api_request_build(self.request)
        api_response   = api_embed_execute(api_parameters)

        process_embed_finished(api_response)
      end

      # Prepares the request for the next iteration.
      #
      # Applies tool/function messages from the message stack and resets
      # the buffer for multi-turn conversations.
      #
      # @return [Request] updated request object
      def prepare_prompt_request
        self.request.messages = [ *request.messages, *message_stack ]
        self.message_stack    = []

        self.request
      end

      # Builds API request parameters from the request object.
      #
      # Converts the request to a hash and configures streaming if enabled.
      #
      # @param request [Request] request object
      # @return [Hash] API request parameters
      def api_request_build(request)
        parameters          = request.to_hc
        parameters[:stream] = process_stream if request.try(:stream)
        parameters
      end

      # Returns a Proc for processing streaming response chunks.
      #
      # @return [Proc] streaming callback proc
      # @see #process_stream_chunk
      def process_stream
        proc do |api_response_chunk|
          process_stream_chunk(api_response_chunk)
        end
      end

      # Executes the prompt API request to the provider.
      #
      # @abstract Subclasses must implement this method
      # @param request_parameters [Hash] parameters to send to the API
      # @return [Object] API response object (format varies by provider)
      # @raise [NotImplementedError] if not implemented by subclass
      def api_prompt_execute(request_parameters)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Executes the embedding API request to the provider.
      #
      # @abstract Subclasses must implement this method
      # @param request_parameters [Hash] parameters to send to the API
      # @return [Object] API embedding response object (format varies by provider)
      # @raise [NotImplementedError] if not implemented by subclass
      def api_embed_execute(request_parameters)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Processes a streaming response chunk.
      #
      # @abstract Subclasses must implement this method
      # @param api_response_chunk [Object] streaming response chunk
      # @return [void]
      # @raise [NotImplementedError] if not implemented by subclass
      def process_stream_chunk(api_response_chunk)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Broadcasts stream open event once per multi-iteration run.
      #
      # @return [void]
      def broadcast_stream_open
        return if streaming
        self.streaming = true

        stream_broadcaster.call(nil, nil, :open)
      end

      # Broadcasts a stream update with message delta.
      #
      # @param message [Hash, Object] current message object
      # @param delta [String, nil] content delta to stream
      # @return [void]
      def broadcast_stream_update(message, delta = nil)
        stream_broadcaster.call(message, delta, :update)
      end

      # Broadcasts stream close event once per multi-iteration run.
      #
      # @return [void]
      def broadcast_stream_close
        return unless streaming
        self.streaming = false

        stream_broadcaster.call(message_stack.last, nil, :close)
      end

      # Processes the completed API response.
      #
      # Extracts messages and function calls. If tool calls exist, processes
      # them and recursively resolves the prompt. Otherwise returns the final response.
      #
      # @param api_response [Object, nil] completed API response
      # @return [Object, nil] final api_response
      def process_prompt_finished(api_response = nil)
        if (api_messages = process_prompt_finished_extract_messages(api_response))
          message_stack.push(*api_messages)
        end

        if (tool_calls = process_prompt_finished_extract_function_calls)&.any?
          process_function_calls(tool_calls)
          resolve_prompt
        else

          # During a multi iteration process, we will internally open/close the stream
          # with the provider, but this should all look like one big stream to the agents
          # as they continue to work.
          broadcast_stream_close

          # To convert the messages into common format we first need to merge the current
          # stack and then cast them to the provider type, so we can cast them out to common.
          messages = prompt_request_klass.new(
            messages: [ *request.messages, *message_stack ]
          ).messages

          # This will returned as it closes up the recursive stack
          Common::PromptResponse.new(
            context:,
            raw_request:  request.to_hc,
            raw_response: api_response,
            messages:
          )
        end
      end

      # Extracts messages from the API response.
      #
      # @abstract Subclasses must implement this method
      # @param api_response [Object] API response object
      # @return [Array<Message>, nil] message objects or nil
      # @raise [NotImplementedError] if not implemented by subclass
      def process_prompt_finished_extract_messages(api_response)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Extracts function/tool calls from the API response.
      #
      # @abstract Subclasses must implement this method
      # @return [Array<Hash>, nil] function call hashes or nil
      # @raise [NotImplementedError] if not implemented by subclass
      def process_prompt_finished_extract_function_calls
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Processes the completed embedding API response.
      #
      # Constructs a standardized EmbedResponse object from the provider's
      # raw API response.
      #
      # @param api_response [Hash] completed embedding API response
      # @return [Common::EmbedResponse] standardized embedding response
      def process_embed_finished(api_response)
        Common::EmbedResponse.new(
          context:,
          raw_request:  request.to_hc,
          raw_response: api_response,
          data: process_embed_finished_data(api_response)
        )
      end

      # Extracts embedding data from API response.
      #
      # Handles both list and object response formats:
      # - List format: `{ "data": [{ "embedding": [...] }] }`
      # - Object format: `{ "embedding": [...] }`
      #
      # @param api_response [Hash] API response containing embeddings
      # @return [Array<Hash>] array of embedding objects with index, object type, and embedding vector
      # @raise [RuntimeError] if response format is unexpected
      def process_embed_finished_data(api_response)
        case (type = api_response[:object])
        when "list"
          api_response[:data]
        when "embedding"
          [ { index: 0 }.merge(api_response.slice(:index, :object, :embedding)) ]
        else
          fail "Unexpected Embed Object Type: #{type}"
        end
      end
    end
  end
end
