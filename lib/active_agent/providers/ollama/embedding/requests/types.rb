# frozen_string_literal: true

require_relative "options"

module ActiveAgent
  module Providers
    module Ollama
      module Embedding
        module Requests
          module Types
            # Custom type for handling embedding input
            # Can be a string or array of strings
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

            # Custom type for handling options parameter
            # Can be a hash or Options object
            class OptionsType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Options
                  value
                when Hash
                  Options.new(**value.symbolize_keys)
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Options"
                end
              end

              def serialize(value)
                case value
                when Options
                  value.to_h
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
  end
end
