# frozen_string_literal: true

require_relative "options"
require_relative "request"
require_relative "embedding_request"

module ActiveAgent
  module Providers
    module RubyLLM
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

      # Type for embedding requests
      class EmbeddingRequestType < ActiveModel::Type::Value
        def cast(value)
          case value
          when RubyLLM::EmbeddingRequest
            value
          when Hash
            RubyLLM::EmbeddingRequest.new(**value.deep_symbolize_keys)
          when nil
            nil
          else
            raise ArgumentError, "Cannot cast #{value.class} to EmbeddingRequest"
          end
        end

        def serialize(value)
          case value
          when RubyLLM::EmbeddingRequest
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
