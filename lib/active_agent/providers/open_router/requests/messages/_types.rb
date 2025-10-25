# frozen_string_literal: true

require "active_agent/providers/open_ai/chat/requests/messages/_types"

require_relative "assistant"
require_relative "user"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          # Type for Messages array - uses OpenRouter's MessageType
          class MessagesType < OpenAI::Chat::Requests::Messages::MessagesType
            def initialize
              super
              @message_type = MessageType.new
            end
          end

          class MessageType < OpenAI::Chat::Requests::Messages::MessageType
            def cast(value)
              case value
              when OpenAI::Chat::Requests::Messages::Base
                value
              when String
                User.new(content: value)
              when Hash
                hash = value.deep_symbolize_keys
                role = hash[:role]&.to_sym

              case role
              when :developer
                OpenAI::Chat::Requests::Messages::Developer.new(**hash)
              when :system
                OpenAI::Chat::Requests::Messages::System.new(**hash)
              when :user, nil
                User.new(**hash)
              when :assistant
                Assistant.new(**hash)
              when :tool
                OpenAI::Chat::Requests::Messages::Tool.new(**hash)
              when :function
                OpenAI::Chat::Requests::Messages::Function.new(**hash)
              else
                raise ArgumentError, "Unknown message role: #{role.inspect}"
              end
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Message (expected Base, String, Hash, or nil)"
              end
            end
          end
        end
      end
    end
  end
end
