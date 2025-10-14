# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module ParameterBuilder
      extend ActiveSupport::Concern

      protected

      # Merge parameters with proper precedence:
      # 1. ??? Action Overrides (highest priority)
      # 2. Prompt
      # 3. Provider [via Provider Setup]
      # 4. Default (lowest priority) [Applied via Options Attribute Defaults]
      def generate_prompt_parameters(prompt)
        agent_params   = options.prompt_parameters                   # Agent-Provider Level Params
        action_params  = options_type.new(**(prompt.options || {}))  # Action-Prompt Level Params
        message_params = generate_prompt_parameters_messages(prompt) # Action-Prompt Messages

        # Merge together the simple parameters
        request_payload = agent_params.merge(action_params).merge(message_params)

        # @TODO - Add Middleware Style Injection to make it easier extend
        request_payload
      end

      def generate_prompt_parameters_messages(prompt)
        { messages: provider_messages(prompt.messages) }
      end

      # Base
      # # Add optional parameters if present
      # params[:tools] = format_tools(prompt.actions) if prompt.actions.present?

      # Embedding-specific parameters
      def embeddings_parameters(input: nil, model: nil, **options)
        {
          model: model || determine_embedding_model,
          input: input || format_embedding_input,
          dimensions: options[:dimensions] || @config["embedding_dimensions"],
          encoding_format: options[:encoding_format] || "float"
        }.compact
      end

      def determine_embedding_model(prompt)
        prompt.options[:embedding_model] || @config["embedding_model"] || "text-embedding-3-small"
      end

      def format_embedding_input(prompt)
        # Handle single or batch embedding inputs
        if prompt.message
          prompt.message.content
        elsif prompt.messages
          prompt.messages.map(&:content)
        else
          nil
        end
      end
    end
  end
end
