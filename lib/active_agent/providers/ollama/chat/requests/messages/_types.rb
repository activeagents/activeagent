# frozen_string_literal: true

require_relative "assistant"
require_relative "user"

module ActiveAgent
  module Providers
    module Ollama
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
            # Inherits from OpenAI but handles Ollama-specific message types
            class MessageType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Assistant, User
                  value
                when OpenAI::Chat::Requests::Messages::Base
                  value
                when Hash
                  role = value[:role]&.to_s || value["role"]&.to_s

                  case role
                  when "assistant"
                    Assistant.new(**value.symbolize_keys)
                  when "user"
                    User.new(**value.symbolize_keys)
                  when "system"
                    # Ollama doesn't have system message, use OpenAI's
                    OpenAI::Chat::Requests::Messages::System.new(**value.symbolize_keys)
                  when "tool"
                    OpenAI::Chat::Requests::Messages::Tool.new(**value.symbolize_keys)
                  else
                    # Fall back to OpenAI's message type
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
                when OpenAI::Chat::Requests::Messages::Base
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
