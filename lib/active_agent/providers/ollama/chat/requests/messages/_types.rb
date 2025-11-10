# frozen_string_literal: true

require "active_agent/providers/open_ai/chat/requests/messages/_types"

require_relative "assistant"
require_relative "user"

module ActiveAgent
  module Providers
    module Ollama
      module Chat
        module Requests
          module Messages
            # Type for Messages array - uses Ollama's MessageType
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
            # Inherits from OpenAI but handles Ollama-specific message types
            class MessageType < OpenAI::Chat::Requests::Messages::MessageType
              def cast(value)
                case value
                when Assistant, User
                  value
                when OpenAI::Chat::Requests::Messages::Base
                  value
                when String
                  User.new(content: value)
                when Hash
                  hash = value.deep_symbolize_keys
                  role = hash[:role]&.to_sym

                  case role
                  when :assistant
                    Assistant.new(**hash)
                  when :user, nil
                    User.new(**hash)
                  when :system
                    OpenAI::Chat::Requests::Messages::System.new(**hash)
                  when :developer
                    OpenAI::Chat::Requests::Messages::Developer.new(**hash)
                  when :tool
                    OpenAI::Chat::Requests::Messages::Tool.new(**hash)
                  else
                    raise ArgumentError, "Unknown message role: #{role.inspect}"
                  end
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Message (expected Assistant, User, OpenAI Message, Hash, or nil)"
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
                  raise ArgumentError, "Cannot serialize #{value.class} as Message"
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
