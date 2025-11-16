# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        # Response format configuration for structured output
        #
        # Enables JSON-formatted responses using OpenAI's structured output format.
        # When using structured output, OpenRouter automatically sets
        # provider.require_parameters=true to route to compatible models.
        #
        # @example JSON object format
        #   format = ResponseFormat.new(type: 'json_object')
        #
        # @example JSON schema format
        #   format = ResponseFormat.new(
        #     type: 'json_schema',
        #     json_schema: {
        #       name: 'user_profile',
        #       description: 'A user profile',
        #       schema: { type: 'object', properties: { name: { type: 'string' } } },
        #       strict: true
        #     }
        #   )
        #
        # @see https://openrouter.ai/docs/structured-outputs OpenRouter Structured Outputs
        # @see https://platform.openai.com/docs/guides/structured-outputs OpenAI Structured Outputs
        class ResponseFormat < Common::BaseModel
          # @!attribute type
          #   @return [String] response format type ('json_object' or 'json_schema')
          attribute :type, :string

          # @!attribute json_schema
          #   @return [Hash, nil] JSON schema configuration (required when type is 'json_schema')
          #   @option json_schema [String] :name schema name (max 64 chars, alphanumeric/underscore/dash)
          #   @option json_schema [String] :description schema description
          #   @option json_schema [Hash] :schema JSON schema definition
          #   @option json_schema [Boolean] :strict whether to enforce strict schema adherence
          attribute :json_schema # Hash with name, description, schema, strict

          validates :type, inclusion: { in: %w[json_object json_schema] }, allow_nil: true

          # Validate that json_schema is present when type is json_schema
          validate :validate_json_schema_presence

          private

          def validate_json_schema_presence
            if type == "json_schema" && json_schema.blank?
              errors.add(:json_schema, "must be present when type is 'json_schema'")
            end

            if json_schema.present? && json_schema.is_a?(Hash)
              validate_json_schema_structure
            end
          end

          def validate_json_schema_structure
            unless json_schema[:name].present?
              errors.add(:json_schema, "must include 'name' field")
            end

            if json_schema[:name].present? && json_schema[:name].length > 64
              errors.add(:json_schema, "name must be 64 characters or less")
            end

            # Name must match pattern: a-z, A-Z, 0-9, underscores and dashes
            if json_schema[:name].present? && json_schema[:name] !~ /^[a-zA-Z0-9_-]+$/
              errors.add(:json_schema, "name must contain only a-z, A-Z, 0-9, underscores and dashes")
            end
          end
        end
      end
    end
  end
end
