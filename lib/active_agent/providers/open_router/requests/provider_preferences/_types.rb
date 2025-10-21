# frozen_string_literal: true

require_relative "max_price"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        # Type for MaxPrice
        class MaxPriceType < ActiveModel::Type::Value
          def cast(value)
            case value
            when MaxPrice
              value
            when Hash
              MaxPrice.new(**value.deep_symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to MaxPrice"
            end
          end

          def serialize(value)
            case value
            when MaxPrice
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
