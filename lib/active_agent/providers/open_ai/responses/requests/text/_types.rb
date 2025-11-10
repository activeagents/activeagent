# frozen_string_literal: true

require_relative "base"
require_relative "plain"
require_relative "json_object"
require_relative "json_schema"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module TextFormats
            # ActiveModel type for casting and serializing Text format objects
            class FormatType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Plain, JsonObject, JsonSchema
                  value
                when Hash
                  create_format_from_hash(value)
                when String
                  create_format_from_string(value)
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Format"
                end
              end

              def serialize(value)
                case value
                when Plain, JsonObject, JsonSchema
                  value.serialize
                when Hash
                  value
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot serialize #{value.class}"
                end
              end

              def deserialize(value)
                cast(value)
              end

              private

              def create_format_from_hash(hash)
                hash = hash.deep_symbolize_keys
                type = hash[:type]

                case type
                when "text"
                  Plain.new
                when "json_object"
                  JsonObject.new
                when "json_schema"
                  JsonSchema.new(
                    name: hash[:name],
                    description: hash[:description],
                    schema: hash[:schema],
                    strict: hash[:strict]
                  )
                else
                  nil
                end
              end

              def create_format_from_string(value)
                case value
                when "text"
                  Plain.new
                when "json_object"
                  JsonObject.new
                when "json_schema"
                  JsonSchema.new
                else
                  nil
                end
              end
            end
          end
        end
      end
    end
  end
end
