# frozen_string_literal: true

require_relative "base"
require_relative "enabled"
require_relative "disabled"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ThinkingConfig
          # Type for ThinkingConfig
          class ThinkingConfigType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Base
                value
              when Hash
                # Symbolize keys once for consistent lookups
                hash = value.symbolize_keys
                type = hash[:type]&.to_s

                case type
                when "enabled"
                  Enabled.new(**hash)
                when "disabled"
                  Disabled.new(**hash)
                when nil
                  nil
                else
                  raise ArgumentError, "Unknown thinking config type: #{type}"
                end
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to ThinkingConfig"
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
