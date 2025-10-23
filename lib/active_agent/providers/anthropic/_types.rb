# frozen_string_literal: true

require_relative "requests/_types"

require_relative "options"
require_relative "request"

module ActiveAgent
  module Providers
    module Anthropic
      # ActiveModel type for casting and serializing Anthropic Request objects.
      #
      # Handles conversion between Hash, Request, and serialized formats for API calls.
      class RequestType < ActiveModel::Type::Value
        # Casts input to Request object.
        #
        # @param value [Request, Hash, nil]
        # @return [Request, nil]
        # @raise [ArgumentError] when value cannot be cast to Request
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

        # Serializes Request to Hash for API submission.
        #
        # Removes `:response_format` key as it's a simulated feature not directly
        # supported by Anthropic's API.
        #
        # @param value [Request, Hash, nil]
        # @return [Hash, nil]
        # @raise [ArgumentError] when value cannot be serialized
        def serialize(value)
          case value
          when Request
            # Response Format is a simulated feature, not directly supported by API
            value.serialize.except(:response_format)
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
