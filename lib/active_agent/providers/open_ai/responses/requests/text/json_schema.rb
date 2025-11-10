# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module TextFormats
            # JSON schema format for structured outputs
            class JsonSchema < Base
              attribute :type, :string, as: "json_schema"

              # Name of the response format
              attribute :name, :string

              # Description of what the response format is for
              attribute :description, :string

              # The JSON schema object
              attribute :schema # Hash

              # Whether to enable strict schema adherence
              attribute :strict, :boolean, default: false

              validates :name, presence: true
              validates :schema, presence: true

              validate :validate_schema_structure

              private

              def validate_schema_structure
                return if schema.blank?
                return unless schema.is_a?(Hash)

                unless schema.key?("type") || schema.key?(:type)
                  errors.add(:schema, "must include a 'type' property")
                end
              end
            end
          end
        end
      end
    end
  end
end
