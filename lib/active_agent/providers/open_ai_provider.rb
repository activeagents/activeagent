require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai/_base"
require_relative "open_ai/chat_provider"
require_relative "open_ai/responses_provider"
require_relative "open_ai/embedding/_types"

module ActiveAgent
  module Providers
    # Router for OpenAI's API versions based on supported features.
    #
    # This provider acts as a thin wrapper that routes requests between different versions
    # of OpenAI's API (Chat API and Responses API) depending on the features used in the prompt.
    # It automatically selects the appropriate API version based on:
    # - Explicit API version specification (+:api_version+ option)
    # - Presence of audio content in the request
    #
    # @example Basic usage
    #   provider = ActiveAgent::Providers::OpenAIProvider.new(...)
    #   result = provider.generate
    #
    # @see https://platform.openai.com/docs/guides/migrate-to-responses
    class OpenAIProvider < OpenAI::Base
      attr_internal :api_version
      attr_internal :raw_options

      # Initializes the OpenAI provider router.
      #
      # Since this layer is just routing based on API version, we want to wait
      # to cast values into their types.
      #
      # @param kwargs [Hash] Configuration options for the provider
      # @option kwargs [Symbol] :service The service name to validate
      # @option kwargs [Symbol] :api_version The OpenAI API version to use (:chat or :responses)
      def initialize(kwargs = {})
        # For Routing Prompt APIs
        self.api_version = kwargs.delete(:api_version)
        self.raw_options = kwargs.deep_dup

        super
      end

      # Generates a response by routing to the appropriate OpenAI API version.
      #
      # This method determines which API version to use based on the prompt context:
      # - Uses Chat API if +api_version: :chat+ is specified or audio is present
      # - Uses Responses API otherwise (default)
      #
      # @return [Object] The generation result from the selected API provider
      #
      # @see https://platform.openai.com/docs/guides/migrate-to-responses
      def prompt
        if api_version == :chat || context[:audio].present?
          instrument("api_routing.provider.active_agent", api_type: :chat, api_version: api_version, has_audio: context[:audio].present?)
          OpenAI::ChatProvider.new(raw_options).prompt
        else # api_version == :responses || true
          instrument("api_routing.provider.active_agent", api_type: :responses, api_version: api_version)
          OpenAI::ResponsesProvider.new(raw_options).prompt
        end
      end

      # Returns the embedding request type for OpenAI.
      #
      # @return [ActiveModel::Type::Value] The OpenAI embedding request type
      def embed_request_type = OpenAI::Embedding::RequestType.new

      protected

      # Executes an embedding request via OpenAI's API.
      #
      # @param parameters [Hash] The embedding request parameters
      # @return [Object] The embedding response from OpenAI
      def api_embed_execute(parameters)
        instrument("embeddings_request.provider.active_agent")
        client.embeddings(parameters:).deep_symbolize_keys
      end
    end
  end
end
