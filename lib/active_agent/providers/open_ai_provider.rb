require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai/_base_provider"
require_relative "open_ai/chat_provider"
require_relative "open_ai/responses_provider"

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
    #   result = provider.generate(resolver)
    #
    # @see https://platform.openai.com/docs/guides/migrate-to-responses
    class OpenAIProvider < OpenAI::BaseProvider
      attr_internal :api_version

      # Since this layer is just routing based on API version, we want to wait
      # to cast values into their times.
      def initialize(kwargs = {})
        self.api_version = kwargs.delete(:api_version)
        self.context     = kwargs
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
      def call
        if api_version == :chat || context[:audio].present?
          OpenAI::ChatProvider.new(context).call
        else # api_version == :responses || true
          OpenAI::ResponsesProvider.new(context).call
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
    end
  end
end
