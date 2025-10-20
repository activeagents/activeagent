# frozen_string_literal: true

require_relative "base"
require_relative "auto"
require_relative "any"
require_relative "tool"
require_relative "none"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ToolChoice
          # Type for ToolChoice
          class ToolChoiceType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Base
                value
              when Hash
                # Symbolize keys once for consistent lookups
                hash = value.symbolize_keys
                type = hash[:type]&.to_s

                case type
                when "auto"
                  Auto.new(**hash)
                when "any"
                  Any.new(**hash)
                when "tool"
                  Tool.new(**hash)
                when "none"
                  None.new(**hash)
                when nil
                  nil
                else
                  raise ArgumentError, "Unknown tool choice type: #{type}"
                end
              when String
                # Allow string shortcuts like "auto", "any", "none"
                case value
                when "auto"
                  Auto.new
                when "any"
                  Any.new
                when "none"
                  None.new
                else
                  raise ArgumentError, "Unknown tool choice: #{value}"
                end
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to ToolChoice"
              end
            end

            def serialize(value)
              case value
              when Base
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
  end
end
