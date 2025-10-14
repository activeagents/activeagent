require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai/_base_provider"
require_relative "open_ai/chat_provider"
require_relative "open_ai/responses_provider"

module ActiveAgent
  module GenerationProvider
    # Thin wrapper to router between the different versions of OpenAI's API based on supported features
    class OpenAIProvider < OpenAI::BaseProvider
      # @see https://platform.openai.com/docs/guides/migrate-to-responses
      def generate(prompt)
        if prompt_has_audio?(prompt)
          OpenAI::ChatProvider.new(@options.to_h).generate(prompt)
        else
          OpenAI::ResponsesProvider.new(@options.to_h).generate(prompt)
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

      def prompt_has_audio?(prompt)
        false
      end
    end
  end
end
