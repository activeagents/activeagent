# frozen_string_literal: true

# Load all message classes
require_relative "base"
require_relative "system"
require_relative "user"
require_relative "assistant"
require_relative "tool"

module ActiveAgent
  module Providers
    module RubyLLM
      module Messages
        # Type for Messages array
        class MessagesType < ActiveModel::Type::Value
          def initialize
            super
            @message_type = MessageType.new
          end

          def cast(value)
            case value
            when Array
              value.map { |v| @message_type.cast(v) }
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to Messages array"
            end
          end

          def serialize(value)
            case value
            when Array
              grouped = []

              value.each do |message|
                if grouped.empty? || grouped.last.role != message.role
                  grouped << message.deep_dup
                else
                  grouped.last.content += message.content.deep_dup
                end
              end

              grouped.map { |v| @message_type.serialize(v) }
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

        # Type for individual Message
        class MessageType < ActiveModel::Type::Value
          def cast(value)
            case value
            when Base
              value
            when String
              User.new(content: value)
            when Hash
              hash = value.deep_symbolize_keys
              role = hash[:role]&.to_sym

              case role
              when :user, nil
                User.new(**hash)
              when :assistant
                Assistant.new(**hash)
              when :system
                System.new(**hash)
              when :tool
                Tool.new(**hash)
              else
                raise ArgumentError, "Unknown message role: #{role}"
              end
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to Message"
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
