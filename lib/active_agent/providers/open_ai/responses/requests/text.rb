# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          class Text < Common::BaseModel
            # Format for text output
            attribute :format, :string

            # Modalities for output
            attribute :modalities, default: -> { [] } # Array of strings

            # JSON schema for structured outputs
            attribute :json_schema # Hash containing the schema definition

            validates :format, inclusion: { in: %w[text json_object json_schema] }, allow_nil: true

            # Validate that json_schema is present when format is json_schema
            validate :validate_json_schema_presence

            private

            def validate_json_schema_presence
              if format == "json_schema" && json_schema.blank?
                errors.add(:json_schema, "must be present when format is 'json_schema'")
              end
            end
          end
        end
      end
    end
  end
end
