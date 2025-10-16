# frozen_string_literal: true

require_relative "../open_ai/chat/request"
require_relative "requests/message"
require_relative "requests/types"

module ActiveAgent
  module Providers
    module Ollama
      # Ollama uses the same request structure as OpenAI's chat completion API
      # This class exists to allow for Ollama-specific customizations.
      class Request < OpenAI::Chat::Request
        # Messages array (required)
        attribute :messages, Requests::Types::MessagesType.new
      end
    end
  end
end
