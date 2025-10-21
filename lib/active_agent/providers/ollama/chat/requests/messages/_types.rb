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
                  hash = value.deep_symbolize_keys
                  role = hash[:role]&.to_sym

                  case role
                  when :assistant
                    Assistant.new(**hash)
                  when :user
                    User.new(**hash)
                  when :system
                    # Ollama doesn't have system message, use OpenAI's
                    OpenAI::Chat::Requests::Messages::System.new(**hash)
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
