# frozen_string_literal: true

# Load all message classes
require_relative "base"
require_relative "developer"
require_relative "system"
require_relative "user"
require_relative "assistant"
require_relative "tool"
require_relative "function"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            # Type for Messages array
            class MessagesType < ActiveModel::Type::Value
              def initialize
                super
                @message_type = MessageType.new
              end

              def cast(value)
                return nil if value.nil?
                return [] if value == []

                array = Array(value)
                array.map { |msg| @message_type.cast(msg) }
              end

              def serialize(value)
                return nil if value.nil?
                return [] if value == []

                array = Array(value)
                array.map { |msg| @message_type.serialize(msg) }
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
                when Hash
                  role = value[:role]&.to_s || value["role"]&.to_s

                  case role
                  when "developer"
                    Developer.new(**value.symbolize_keys)
                  when "system"
                    System.new(**value.symbolize_keys)
                  when "user"
                    User.new(**value.symbolize_keys)
                  when "assistant"
                    Assistant.new(**value.symbolize_keys)
                  when "tool"
                    Tool.new(**value.symbolize_keys)
                  when "function"
                    Function.new(**value.symbolize_keys)
                  else
                    # If no role specified or unknown, return as-is
                    value
                  end
                when nil
                  nil
                else
                  value
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
                  value
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
