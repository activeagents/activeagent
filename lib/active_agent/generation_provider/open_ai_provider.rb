require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai/_base_provider"
require_relative "open_ai/chat_provider"
require_relative "open_ai/responses_provider"

module ActiveAgent
  module GenerationProvider
    # Thin wrapper to router between the different versions of OpenAI's API based on supported features
    class OpenAIProvider < OpenAI::BaseProvider
      # Since we are routing between two different API versions that may/will have different
      # available options, we keep them as untyped hashes until generation which will route.
      def initialize(options = {})
        fail "Unexpected Service Name: #{options["service"]} != #{service_name}" if options["service"] && options["service"] != service_name

        self.options = (options || {}).except("service").deep_symbolize_keys
      end

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

      def prompt_chat_api?(prompt_context)
        prompt_context[:api_version] == :chat
      end

      def prompt_has_audio?(prompt_context)
        prompt_context[:audio].present?
      end
    end
  end
end
