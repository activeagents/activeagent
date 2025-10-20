# frozen_string_literal: true

require_relative "../../open_ai/chat/request"
require_relative "requests/_types"

module ActiveAgent
  module Providers
    module Ollama
      module Chat
        # Ollama uses the same request structure as OpenAI's chat completion API
        # This class exists to allow for Ollama-specific customizations.
        class Request < OpenAI::Chat::Request
          # Messages array (required)
          attribute :messages, Requests::Messages::MessagesType.new

          # Common Format Compatability
          def messages=(value)
            case value
            when Array
              super((messages || []) | value)
            else
              super((messages || []) | [ value ])
            end
          end
        end
      end
    end
  end
end
