# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Ollama
      module Chat
        module Requests
          module Types
            class MessageType < OpenAI::Chat::Requests::Types::MessageType
              def cast(value)
                case value
                when Hash
                  role = value[:role]&.to_s || value["role"]&.to_s

                  case role
                  when "assistant"
                    Messages::Assistant.new(**value.symbolize_keys)
                  when "user"
                    Messages::User.new(**value.symbolize_keys)
                  else
                    super
                  end
                else
                  super
                end
              end
            end

            class MessagesType < OpenAI::Chat::Requests::Types::MessagesType
              def initialize
                super
                @message_type = MessageType.new
              end
            end
          end
        end
      end
    end
  end
end
