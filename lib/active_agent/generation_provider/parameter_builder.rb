# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module ParameterBuilder
      extend ActiveSupport::Concern

      def prompt_parameters(overrides = {})
        base_params = build_base_parameters
        provider_params = build_provider_parameters

        # Merge parameters with proper precedence:
        # 1. Overrides (highest priority)
        # 2. Prompt options
        # 3. Provider-specific parameters
        # 4. Base parameters (lowest priority)
        base_params
          .merge(provider_params)
          .merge(extract_prompt_options)
          .merge(overrides)
          .compact
      end

      protected

      def build_base_parameters
        {
          model: determine_model,
          messages: provider_messages(@prompt.messages),
          temperature: determine_temperature
        }.tap do |params|
          # Add optional parameters if present
          params[:max_tokens] = determine_max_tokens if determine_max_tokens
          params[:tools] = format_tools(@prompt.actions) if @prompt.actions.present?
        end
      end

      def build_provider_parameters
        # Override in provider for specific parameters
        # For example, Anthropic needs 'system' parameter instead of system message
        {}
      end

      def extract_prompt_options
        # Extract relevant options from prompt
        options = {}

        # Common options that map directly
        [ :stream, :top_p, :frequency_penalty, :presence_penalty, :seed, :stop, :user ].each do |key|
          options[key] = @prompt.options[key] if @prompt.options.key?(key)
        end

        # Handle response format for structured output
        if @prompt.output_schema.present?
          options[:response_format] = build_response_format
        end

        options
      end

      def determine_model
        @prompt.options[:model] || @model_name || @config["model"]
      end

      def determine_temperature
        @prompt.options[:temperature] || @config["temperature"] || 0.7
      end

      def determine_max_tokens
        @prompt.options[:max_tokens] || @config["max_tokens"]
      end

      def build_response_format
        # Default OpenAI-style response format
        # Override in provider for different formats
        {
          type: "json_schema",
          json_schema: @prompt.output_schema
        }
      end

      # Embedding-specific parameters
      def embeddings_parameters(input: nil, model: nil, **options)
        {
          model: model || determine_embedding_model,
          input: input || format_embedding_input,
          dimensions: options[:dimensions] || @config["embedding_dimensions"],
          encoding_format: options[:encoding_format] || "float"
        }.compact
      end

      def determine_embedding_model
        @prompt.options[:embedding_model] || @config["embedding_model"] || "text-embedding-3-small"
      end

      def format_embedding_input
        # Handle single or batch embedding inputs
        if @prompt.message
          @prompt.message.content
        elsif @prompt.messages
          @prompt.messages.map(&:content)
        else
          nil
        end
      end

      module ClassMethods
        # Class-level configuration for default parameters
        def default_parameters(params = {})
          @default_parameters = params
        end

        def get_default_parameters
          @default_parameters || {}
        end
      end
    end
  end
end
