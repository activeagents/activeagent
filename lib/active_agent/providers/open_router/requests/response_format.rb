# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        class ResponseFormat < Common::BaseModel
          # Type of response format (json_object, json_schema)
          attribute :type, :string

          # JSON schema configuration (only for json_schema type)
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
