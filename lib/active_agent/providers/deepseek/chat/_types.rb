# frozen_string_literal: true

require_relative "request"

module ActiveAgent
  module Providers
    module DeepSeek
      module Chat
        # ActiveModel type for casting and serializing DeepSeek chat requests.
        #
        # @see ActiveAgent::Providers::Ollama::Chat::RequestType
        class RequestType < ActiveModel::Type::Value
          # @param value [Request, Hash, nil]
          # @return [Request, nil]
          # @raise [ArgumentError] if value cannot be cast
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

          # @param value [Request, Hash, nil]
          # @return [Hash, nil]
          # @raise [ArgumentError] if value cannot be serialized
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
