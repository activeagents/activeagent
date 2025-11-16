# frozen_string_literal: true

require_relative "../../transforms"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          # ActiveModel type for casting and normalizing messages
          #
          # Delegates to OpenRouter transforms which use OpenAI's message normalization.
          class MessagesType < ActiveModel::Type::Value
            # Casts value to normalized messages array
            #
            # @param value [Array, String, Hash, nil]
            # @return [Array, nil]
            def cast(value)
              return nil if value.nil?
              Transforms.normalize_messages(value)
            end

            # Serializes messages to hash array
            #
            # @param value [Array, nil]
            # @return [Array, nil]
            def serialize(value)
              return nil if value.nil?

              # If already serialized as hashes, return as-is
              return value if value.is_a?(Array) && value.all? { |m| m.is_a?(Hash) }

              # Otherwise convert gem objects to hashes
              value.map { |msg| Transforms.gem_to_hash(msg) }
            end

            # @param value [Object]
            # @return [Array, nil]
            def deserialize(value)
              cast(value)
            end
          end

          # Kept for backwards compatibility but delegates to MessagesType
          class MessageType < MessagesType
            def cast(value)
              # Single message - wrap in array then unwrap
              result = super(value.is_a?(Array) ? value : [ value ])
              result&.first
            end
          end
        end
      end
    end
  end
end
