# frozen_string_literal: true

require_relative "request"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        # ActiveModel type for casting and serializing chat requests
        class RequestType < ActiveModel::Type::Value
          # Casts value to Request object
          #
          # @param value [Request, Hash, nil]
          # @return [Request, nil]
          # @raise [ArgumentError] when value cannot be cast
          def cast(value)
            case value
            when Request
              value
            when Hash
              Request.new(**value.deep_symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to Request"
            end
          end

          # Serializes Request to hash for API submission
          #
          # @param value [Request, Hash, nil]
          # @return [Hash, nil]
          # @raise [ArgumentError] when value cannot be serialized
          def serialize(value)
            case value
            when Request
              value.serialize
            when Hash
              value
            when nil
              nil
            else
              raise ArgumentError, "Cannot serialize #{value.class}"
            end
          end

          # @param value [Object]
          # @return [Request, nil]
          def deserialize(value)
            cast(value)
          end
        end
      end
    end
  end
end
