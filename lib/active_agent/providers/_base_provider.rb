require_relative "common/response"
require_relative "concerns/retries"

# Maps provider types to their gem dependencies.
# @private
GEM_LOADERS = {
  anthropic: [ "anthropic",   "~> 1.12", "anthropic" ],
  openai:    [ "ruby-openai", "~> 8.3",  "openai" ]
}

# Loads and requires a provider's gem dependency.
#
# @param type [Symbol] provider type (:anthropic, :openai)
# @param file_name [String] provider file path for error context
# @return [void]
# @raise [LoadError] when the required gem is not available
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
    # Base class for LLM provider integrations.
    #
    # Orchestrates API requests, streaming responses, and multi-turn tool calling.
    # Each provider (OpenAI, Anthropic, etc.) subclasses this to implement
    # provider-specific API interactions.
    #
    # @abstract Subclasses must implement {#api_prompt_execute},
    #   {#process_stream_chunk}, {#process_prompt_finished_extract_messages},
    #   and {#process_prompt_finished_extract_function_calls}
    class BaseProvider
      include Retries

      class ProvidersError < StandardError; end

      attr_internal :options, :context,              # Setup
                    :request, :message_stack,        # Runtime
                    :stream_broadcaster, :streaming, # Callback (Streams)
                    :tools_function                  # Callback (Tools)

      # Initializes a provider instance.
      #
      # @param kwargs [Hash] configuration and callbacks
      # @option kwargs [Symbol] :service validates against provider's service name
      # @option kwargs [Proc] :stream_broadcaster invoked for streaming events (:open, :update, :close)
      # @option kwargs [Proc] :tools_function invoked to execute tool/function calls
      # @raise [RuntimeError] when service name doesn't match provider
      def initialize(kwargs = {})
        assert_service!(kwargs.delete(:service))

        configure_retries(
          exception_handler: kwargs.delete(:exception_handler),
          retries:           kwargs.delete(:retries),
          retries_count:     kwargs.delete(:retries_count),
          retries_on:        kwargs.delete(:retries_on)
        )

        self.stream_broadcaster = kwargs.delete(:stream_broadcaster)
        self.streaming          = false
        self.tools_function     = kwargs.delete(:tools_function)
        self.options            = options_klass.new(kwargs.extract!(*options_klass.keys))
        self.context            = kwargs
        self.message_stack      = []
      end

      # Executes a prompt request with error handling.
      #
      # @return [ActiveAgent::Providers::Common::PromptResponse]
      # @raise [StandardError] provider-specific errors wrapped by error handling
      def prompt
        instrument("prompt_start.provider.active_agent") do
          self.request = prompt_request_klass.new(context)
          resolve_prompt
        end
      end

      # Executes an embedding request with error handling.
      #
      # Converts text into vector representations for semantic search and similarity operations.
      #
      # @return [ActiveAgent::Providers::Common::EmbedResponse]
      # @raise [StandardError] provider-specific errors wrapped by error handling
      def embed
        instrument("embed_start.provider.active_agent") do
          self.request = embed_request_klass.new(context)
          resolve_embed
        end
      end

      # @return [String] e.g., "Anthropic", "OpenAI"
      def service_name
        self.class.name.split("::").last.delete_suffix("Provider")
      end

      # @return [String] Module-qualified provider name e.g., "Anthropic", "OpenAI::Chat", "OpenAI::Responses"
      def tag_name
        self.class.name.delete_prefix("ActiveAgent::Providers::").delete_suffix("Provider")
      end

      # @return [Module] e.g., ActiveAgent::Providers::OpenAI
      def namespace
        "#{self.class.name.deconstantize}::#{service_name}".safe_constantize
      end

      # @return [Class]
      def options_klass = namespace::Options

      # @return [Class]
      def prompt_request_klass = namespace::Request

      # @return [Class] provider-specific EmbedRequest class
      # @raise [NotImplementedError] when provider doesn't support embeddings
      def embed_request_klass = fail(NotImplementedError)

      protected

      # Validates service name matches provider.
      #
      # @param name [String, nil]
      # @raise [RuntimeError] on service name mismatch
      def assert_service!(name)
        fail "Unexpected Service Name: #{name} != #{service_name}" if name && name != service_name
      end

      # Instruments an event for logging and metrics.
      #
      # @param name [String] Event name (will be namespaced under active_agent_provider)
      # @param payload [Hash] Additional data to include in the event
      # @yield Block to instrument
      # @return [Object] Result of the block if provided
      def instrument(name, payload = {}, &block)
        full_payload = { provider: service_name, provider_module: tag_name }.merge(payload)
        ActiveSupport::Notifications.instrument(name, full_payload, &block)
      end

      # Orchestrates the complete prompt request lifecycle.
      #
      # Prepares request, executes API call, processes response, and handles
      # recursive tool/function calling until completion.
      #
      # @return [ActiveAgent::Providers::Common::PromptResponse]
      def resolve_prompt
        request = prepare_prompt_request

        instrument("request_prepared.provider.active_agent", message_count: request.messages.size)

        # @todo Validate Request
        api_parameters = api_request_build(request)
        api_response   = instrument("api_call.provider.active_agent", streaming: api_parameters[:stream].present?) do
          retriable { api_prompt_execute(api_parameters) }
        end

        process_prompt_finished(api_response)
      end

      # Orchestrates the complete embedding request lifecycle.
      #
      # @return [ActiveAgent::Providers::Common::EmbedResponse]
      def resolve_embed
        # @todo Validate Request
        api_parameters = api_request_build(self.request)
        api_response   = instrument("embed_call.provider.active_agent") do
          retriable { api_embed_execute(api_parameters) }
        end

        process_embed_finished(api_response)
      end

      # Prepares request for next iteration in multi-turn conversation.
      #
      # Appends messages from message stack and resets buffer for next tool call cycle.
      #
      # @return [Request]
      def prepare_prompt_request
        self.request.messages = [ *request.messages, *message_stack ]
        self.message_stack    = []

        self.request
      end

      # Builds API request parameters from request object.
      #
      # @param request [Request]
      # @return [Hash]
      def api_request_build(request)
        parameters          = request.to_hc
        parameters[:stream] = process_stream if request.try(:stream)
        parameters
      end

      # Creates streaming callback proc.
      #
      # @return [Proc] invoked for each response chunk
      def process_stream
        proc do |api_response_chunk|
          process_stream_chunk(api_response_chunk)
        end
      end

      # Executes prompt request against provider's API.
      #
      # @abstract
      # @param request_parameters [Hash]
      # @return [Object] provider-specific API response
      # @raise [NotImplementedError]
      def api_prompt_execute(request_parameters)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Executes embedding request against provider's API.
      #
      # @abstract
      # @param request_parameters [Hash]
      # @return [Object] provider-specific embedding response
      # @raise [NotImplementedError]
      def api_embed_execute(request_parameters)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Processes a single streaming response chunk.
      #
      # @abstract
      # @param api_response_chunk [Object] provider-specific chunk format
      # @raise [NotImplementedError]
      def process_stream_chunk(api_response_chunk)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Broadcasts stream open event once per request cycle.
      def broadcast_stream_open
        return if streaming
        self.streaming = true

        instrument("stream_open.provider.active_agent")
        stream_broadcaster.call(nil, nil, :open)
      end

      # Broadcasts stream update with message content delta.
      #
      # @param message [Hash, Object] current message state
      # @param delta [String, nil] incremental content chunk
      def broadcast_stream_update(message, delta = nil)
        stream_broadcaster.call(message, delta, :update)
      end

      # Broadcasts stream close event once per request cycle.
      def broadcast_stream_close
        return unless streaming
        self.streaming = false

        instrument("stream_close.provider.active_agent")
        stream_broadcaster.call(message_stack.last, nil, :close)
      end

      # Processes completed API response and handles tool calling recursion.
      #
      # Extracts messages and function calls. If tools were invoked, processes
      # them and recursively resolves the prompt. Otherwise returns final response.
      #
      # @param api_response [Object, nil] provider-specific response
      # @return [Common::PromptResponse, nil]
      def process_prompt_finished(api_response = nil)
        if (api_messages = process_prompt_finished_extract_messages(api_response))
          instrument("messages_extracted.provider.active_agent", message_count: api_messages.size)
          message_stack.push(*api_messages)
        end

        if (tool_calls = process_prompt_finished_extract_function_calls)&.any?
          instrument("tool_calls_processing.provider.active_agent", tool_count: tool_calls.size)
          process_function_calls(tool_calls)

          instrument("multi_turn_continue.provider.active_agent")
          resolve_prompt
        else

          # During a multi iteration process, we will internally open/close the stream
          # with the provider, but this should all look like one big stream to the agents
          # as they continue to work.
          broadcast_stream_close

          instrument("prompt_complete.provider.active_agent", message_count: message_stack.size)

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

      # Extracts messages from API response.
      #
      # @abstract
      # @param api_response [Object]
      # @return [Array<Message>, nil]
      # @raise [NotImplementedError]
      def process_prompt_finished_extract_messages(api_response)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Extracts tool/function calls from API response.
      #
      # @abstract
      # @return [Array<Hash>, nil]
      # @raise [NotImplementedError]
      def process_prompt_finished_extract_function_calls
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Processes completed embedding API response.
      #
      # @param api_response [Hash]
      # @return [Common::EmbedResponse]
      def process_embed_finished(api_response)
        Common::EmbedResponse.new(
          context:,
          raw_request:  request.to_hc,
          raw_response: api_response,
          data: process_embed_finished_data(api_response)
        )
      end

      # Extracts embedding vectors from API response.
      #
      # Handles both list and single embedding response formats:
      # - List: `{ "data": [{ "embedding": [...] }] }`
      # - Single: `{ "embedding": [...] }`
      #
      # @param api_response [Hash]
      # @return [Array<Hash>] embedding objects with :index, :object, :embedding keys
      # @raise [RuntimeError] when response format is unexpected
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
