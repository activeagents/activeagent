# frozen_string_literal: true

require_relative "options"
require_relative "request"

module ActiveAgent
  module Providers
    module OpenRouter
      # Type for Request model
      class RequestType < ActiveModel::Type::Value
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

        def deserialize(value)
          cast(value)
        end
      end
    end
  end
end
