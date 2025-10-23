# frozen_string_literal: true

require_relative "../messages/_types"

require_relative "format"

module ActiveAgent
  module Providers
    module Common
      module Responses
        module Types
          # Type for Messages array - delegates to the shared common messages type
          class MessagesType < Common::Messages::Types::MessagesType
          end

          class FormatType < ActiveModel::Type::Value
            def cast(value)
              case value
              when BaseModel
                Responses::Format.new(**value.serialize)
              when Hash
                Responses::Format.new(**value.deep_symbolize_keys)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Format"
              end
            end

            def serialize(value)
              case value
              when Format
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
