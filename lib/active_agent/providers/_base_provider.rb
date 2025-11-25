require "active_support/delegation"

require_relative "common/response"
require_relative "concerns/exception_handler"
require_relative "concerns/instrumentation"
require_relative "concerns/previewable"
require_relative "concerns/tool_choice_clearing"

# @private
GEM_LOADERS = {
  anthropic: [ "anthropic", "~> 1.12", "anthropic" ],
  openai:    [ "openai",    "~> 0.34", "openai" ]
}

# Requires a provider's gem dependency.
#
# @param type [Symbol] provider type (:anthropic, :openai)
# @param file_name [String] for error context
# @return [void]
# @raise [LoadError] when required gem is not installed
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
    # Orchestrates LLM provider API requests, streaming, and multi-turn tool calling.
    #
    # Each provider (OpenAI, Anthropic, etc.) subclasses this to implement
    # provider-specific API interactions.
    #
    # @abstract Subclasses must implement {#api_prompt_execute},
    #   {#process_stream_chunk}, {#process_prompt_finished_extract_messages},
    #   and {#process_prompt_finished_extract_function_calls}
    class BaseProvider
      extend ActiveSupport::Delegation

      include ExceptionHandler
      include Instrumentation
      include Previewable
      include ToolChoiceClearing

      class ProvidersError < StandardError; end

      attr_internal :options, :context, :trace_id,   # Setup
                    :request, :message_stack,        # Runtime
                    :stream_broadcaster, :streaming, # Callback (Streams)
                    :tools_function,                 # Callback (Tools)
                    :usage_stack                     # Usage Tracking

      # @return [String] e.g., "Anthropic", "OpenAI"
      def self.service_name
        name.split("::").last.delete_suffix("Provider")
      end

      # @return [String] e.g., "Anthropic", "OpenAI::Chat"
      def self.tag_name
        name.delete_prefix("ActiveAgent::Providers::").delete_suffix("Provider")
      end

      # @return [Module] e.g., ActiveAgent::Providers::OpenAI
      def self.namespace
        "#{name.deconstantize}::#{service_name}".safe_constantize
      end

      # @return [Class]
      def self.options_klass
        namespace::Options
      end

      # @return [ActiveModel::Type::Value] for prompt casting/serialization
      def self.prompt_request_type
        namespace::RequestType.new
      end

      # @return [ActiveModel::Type::Value] for embedding casting/serialization
      # @raise [NotImplementedError] when provider doesn't support embeddings
      def self.embed_request_type
        fail(NotImplementedError)
      end

      delegate :service_name, :tag_name, :namespace, :options_klass, :prompt_request_type, :embed_request_type, to: :class

      # @param kwargs [Hash] configuration and callbacks
      # @option kwargs [Symbol] :service validates against provider's service name
      # @option kwargs [Proc] :stream_broadcaster for streaming events (:open, :update, :close)
      # @option kwargs [Proc] :tools_function to execute tool/function calls
      # @raise [RuntimeError] when service name doesn't match provider
      def initialize(kwargs = {})
        assert_service!(kwargs.delete(:service))

        configure_exception_handler(
          exception_handler: kwargs.delete(:exception_handler)
        )

        self.trace_id           = kwargs[:trace_id]
        self.stream_broadcaster = kwargs.delete(:stream_broadcaster)
        self.streaming          = false
        self.tools_function     = kwargs.delete(:tools_function)
        self.options            = options_klass.new(kwargs.extract!(*options_klass.keys))
        self.context            = kwargs
        self.message_stack      = []
        self.usage_stack        = []
      end

      # Generates prompt preview without executing the API call.
      #
      # @return [String] markdown-formatted preview
      def preview
        self.request = prompt_request_type.cast(context.except(:trace_id))
        preview_prompt
      end

      # Executes prompt request with error handling and instrumentation.
      #
      # @return [ActiveAgent::Providers::Common::PromptResponse]
      def prompt
        self.request = prompt_request_type.cast(context.except(:trace_id))

        instrument("prompt.active_agent") do |payload|
          response = resolve_prompt
          instrumentation_prompt_payload(payload, request, response)

          response
        end
      end

      # Executes embedding request with error handling and instrumentation.
      #
      # @return [ActiveAgent::Providers::Common::EmbedResponse]
      def embed
        self.request = embed_request_type.cast(context.except(:trace_id))

        instrument("embed.active_agent") do |payload|
          response = resolve_embed
          instrumentation_embed_payload(payload, request, response)

          response
        end
      end

      protected

      # @param name [String, nil]
      # @raise [RuntimeError] when service name doesn't match provider
      def assert_service!(name)
        fail "Unexpected Service Name: #{name} != #{service_name}" if name && name != service_name
      end

      # @param name [String]
      # @param payload [Hash]
      # @yield block to instrument
      # @return [Object] block result
      def instrument(name, payload = {}, &block)
        full_payload = { provider: service_name, provider_module: tag_name, trace_id: }.merge(payload)
        ActiveSupport::Notifications.instrument(name, full_payload, &block)
      end

      # Orchestrates complete prompt request lifecycle.
      #
      # Handles recursive tool/function calling until completion.
      #
      # @return [ActiveAgent::Providers::Common::PromptResponse]
      def resolve_prompt
        api_parameters = api_request_build(prepare_prompt_request, prompt_request_type)
        api_response = instrument("prompt.provider.active_agent") do |payload|
          raw_response = with_exception_handling { api_prompt_execute(api_parameters) }

          # Instrumentation Context Building
          # Normalize response for instrumentation (providers may return gem objects)
          normalized_response = api_response_normalize(raw_response)
          common_response = Common::PromptResponse.new(raw_response: normalized_response)
          instrumentation_prompt_payload(payload, self.request, common_response)
          usage_stack.push(common_response.usage) if common_response&.usage

          raw_response
        end

        process_prompt_finished(api_response)
      end

      # Orchestrates complete embedding request lifecycle.
      #
      # @return [ActiveAgent::Providers::Common::EmbedResponse]
      def resolve_embed
        api_parameters = api_request_build(self.request, embed_request_type)
        api_response = instrument("embed.provider.active_agent") do |payload|
          raw_response = with_exception_handling { api_embed_execute(api_parameters) }

          # Instrumentation Context Building
          common_response = Common::EmbedResponse.new(raw_response:)
          instrumentation_embed_payload(payload, self.request, common_response)

          raw_response
        end

        process_embed_finished(api_response)
      end

      # Prepares request for next iteration in multi-turn conversation.
      #
      # Appends accumulated messages and resets buffer for next cycle.
      #
      # @return [Request]
      def prepare_prompt_request
        self.request.messages = [ *request.messages, *message_stack ]
        self.message_stack    = []

        self.request
      end

      # @param request [Request]
      # @param request_type [ActiveModel::Type::Value] for serialization
      # @return [Hash] API request parameters
      def api_request_build(request, request_type)
        parameters          = request_type.serialize(request)
        parameters[:stream] = process_stream if request.try(:stream)

        if options.extra_headers.present?
          parameters[:request_options] = { extra_headers: options.extra_headers }.deep_merge(parameters[:request_options] || {})
        end

        parameters
      end

      # @return [Proc] for each response chunk
      def process_stream
        proc do |api_response_chunk|
          process_stream_chunk(api_response_chunk)
        end
      end

      # Executes prompt request against provider's API.
      #
      # @abstract
      # @param parameters [Hash]
      # @return [Object] provider-specific API response
      # @raise [NotImplementedError]
      def api_prompt_execute(parameters)
        unless parameters[:stream]
          api_prompt_executer.create(**parameters)
        else
          api_prompt_executer.stream(**parameters.except(:stream)).each(&parameters[:stream])
          nil
        end
      end

      # Returns provider-specific API executer for prompt requests.
      #
      # Since all currently implemented providers use stainless gems, subclasses
      # only need to override endpoint selection.
      #
      # @abstract
      # @return [Object] provider-specific API client
      # @raise [NotImplementedError]
      def api_prompt_executer
        fail NotImplementedError, "Subclass expected to implement"
      end

      # Normalizes API response for instrumentation.
      #
      # Providers that return gem objects (like Anthropic::Models::Message) should
      # override this to convert to a hash so usage data can be extracted.
      # By default, returns the response as-is (for providers returning hashes).
      #
      # @param api_response [Object] provider-specific API response
      # @return [Hash, Object] normalized response (preferably hash)
      def api_response_normalize(api_response)
        api_response
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

      # Broadcasts stream open event.
      #
      # Fires once per request cycle, even during multi-turn tool calling.
      #
      # @return [void]
      def broadcast_stream_open
        return if streaming
        self.streaming = true

        instrument("stream_open.active_agent")
        stream_broadcaster.call(nil, nil, :open)
      end

      # Broadcasts stream update with message content delta.
      #
      # @param message [Hash, Object]
      # @param delta [String, nil]
      # @return [void]
      def broadcast_stream_update(message, delta = nil)
        stream_broadcaster.call(message, delta, :update)
      end

      # Broadcasts stream close event.
      #
      # Fires once per request cycle, even during multi-turn tool calling.
      #
      # @return [void]
      def broadcast_stream_close
        return unless streaming
        self.streaming = false

        instrument("stream_close.active_agent")
        stream_broadcaster.call(message_stack.last, nil, :close)
      end

      # Processes completed API response and handles tool calling recursion.
      #
      # Extracts messages and function calls. If tools were invoked,
      # executes them and recursively continues until completion.
      #
      # @param api_response [Object, nil] provider-specific response
      # @return [Common::PromptResponse, nil]
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
          messages = prompt_request_type.cast(
            messages: [ *request.messages, *message_stack ]
          ).messages

          # Create response object with usage_stack array for multi-turn cumulative tracking.
          # This will returned as it closes up the recursive stack
          Common::PromptResponse.new(
            context:,
            format: request.response_format,
            messages:,
            raw_request:  prompt_request_type.serialize(request),
            raw_response: api_response,
            usages: usage_stack
          )
        end
      end

      # @abstract
      # @param api_response [Object]
      # @return [Array<Message>, nil]
      # @raise [NotImplementedError]
      def process_prompt_finished_extract_messages(api_response)
        fail NotImplementedError, "Subclass expected to implement"
      end

      # @abstract
      # @return [Array<Hash>, nil]
      # @raise [NotImplementedError]
      def process_prompt_finished_extract_function_calls
        fail NotImplementedError, "Subclass expected to implement"
      end

      # @param api_response [Hash]
      # @return [Common::EmbedResponse]
      def process_embed_finished(api_response)
        Common::EmbedResponse.new(
          context:,
          raw_request:  embed_request_type.serialize(request),
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
        case (type = api_response[:object].to_sym)
        when :list
          api_response[:data]
        when :embedding
          [ { index: 0 }.merge(api_response.slice(:index, :object, :embedding)) ]
        else
          fail "Unexpected Embed Object Type: #{type}"
        end
      end
    end
  end
end
