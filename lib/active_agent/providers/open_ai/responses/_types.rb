# frozen_string_literal: true

require_relative "request"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
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
              hash = value.serialize

              if hash[:input] in [ { role: "user", content: String } ]
                hash[:input] = hash[:input][0][:content]
              end

              hash
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
end
