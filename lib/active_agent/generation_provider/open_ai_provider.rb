require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai/_base_provider"
require_relative "open_ai/chat_provider"
require_relative "open_ai/responses_provider"

module ActiveAgent
  module GenerationProvider
    # Router for OpenAI's API versions based on supported features.
    #
    # This provider acts as a thin wrapper that routes requests between different versions
    # of OpenAI's API (Chat API and Responses API) depending on the features used in the prompt.
    # It automatically selects the appropriate API version based on:
    # - Explicit API version specification (+:api_version+ option)
    # - Presence of audio content in the request
    #
    # @example Basic usage
    #   provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(...)
    #   result = provider.generate(resolver)
    #
    # @see https://platform.openai.com/docs/guides/migrate-to-responses
    class OpenAIProvider < OpenAI::BaseProvider
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
      def initialize(options = {})
        fail "Unexpected Service Name: #{options["service"]} != #{service_name}" if options["service"] && options["service"] != service_name

        self.options = (options || {}).except("service").deep_symbolize_keys
      end

      # Generates a response by routing to the appropriate OpenAI API version.
      #
      # This method determines which API version to use based on the prompt context:
      # - Uses Chat API if +api_version: :chat+ is specified or audio is present
      # - Uses Responses API otherwise (default)
      #
      # @param resolver [Object] The resolver containing the prompt context and configuration
      # @return [Object] The generation result from the selected API provider
      #
      # @see https://platform.openai.com/docs/guides/migrate-to-responses
      def generate(resolver)
        prompt_context = options.merge(resolver.context)

        if prompt_chat_api?(prompt_context) || prompt_has_audio?(prompt_context)
          OpenAI::ChatProvider.new(options.to_h).generate(resolver)
        else # prompt_responses_api?(prompt_context) || true
          OpenAI::ResponsesProvider.new(options.to_h).generate(resolver)
        end
      end

      protected

      # def embed(prompt)
      #   with_error_handling do
      #     prompt_with_embeddings(parameters: embeddings_parameters)
      #   end
      # end

      # def prompt_with_embeddings(parameters:)
      #   params = embeddings_parameters
      #   embeddings_response(client.embeddings(parameters: params), params)
      # end

      # def embeddings_parameters(input: prompt.message.content, model: "text-embedding-3-large")
      #   {
      #     model: model,
      #     input: input
      #   }
      # end
      #

      private

      # Checks if the Chat API was explicitly requested.
      #
      # @param prompt_context [Hash] The merged options and resolver context
      # @return [Boolean] true if api_version is set to :chat
      def prompt_chat_api?(prompt_context)
        prompt_context[:api_version] == :chat
      end

      # Checks if the prompt contains audio content.
      #
      # @param prompt_context [Hash] The merged options and resolver context
      # @return [Boolean] true if audio configuration is present
      def prompt_has_audio?(prompt_context)
        prompt_context[:audio].present?
      end
    end
  end
end
