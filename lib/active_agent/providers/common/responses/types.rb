# frozen_string_literal: true

require_relative "../messages/system"
require_relative "../messages/user"
require_relative "../messages/assistant"
require_relative "../messages/tool"

module ActiveAgent
  module Providers
    module Common
      module Responses
        module Types
          # Type for Messages array
          class MessagesType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Array
                value.map { |v| cast_message(v) }
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Messages array"
              end
            end

            def serialize(value)
              case value
              when Array
                value.map { |v| serialize_message(v) }
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end

            private

            def cast_message(value)
              case value
              when Common::Messages::Base
                value
              when Hash
                role = value[:role]&.to_s || value["role"]&.to_s
                case role
                when "system"
                  nil # System messages are dropped in common responses, and replaced by Instructions
                when "user"
                  Common::Messages::User.new(**value.symbolize_keys)
                when "assistant"
                  Common::Messages::Assistant.new(**value.symbolize_keys)
                when "tool"
                  Common::Messages::Tool.new(**value.symbolize_keys)
                else
                  raise ArgumentError, "Unknown message role: #{role}"
                end
              else
                # Check if the value responds to to_common (provider-specific message)
                if value.respond_to?(:to_common)
                  cast_message(value.to_common)
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Message"
                end
              end
            end

            def serialize_message(value)
              case value
              when Common::Messages::Base
                value.to_h
              when Hash
                value
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end
          end
        end
      end
    end
  end
end
