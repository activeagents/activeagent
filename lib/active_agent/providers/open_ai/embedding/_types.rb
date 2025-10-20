# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenAI
      module Embedding
        module Requests
          # Custom type for handling embedding input
          # Can be a string, array of strings, or array of token arrays
          # Always stores internally as an array for consistency
          class InputType < ActiveModel::Type::Value
            def cast(value)
              case value
              when String
                [ value.presence ].compact
              when Array
                value.compact
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Input (expected String or Array)"
              end
            end

            def serialize(value)
              case value
              when Array
                # Return single string if array has only one string element
                if value.length == 1 && value.first.is_a?(String)
                  value.first
                else
                  value
                end
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
end
