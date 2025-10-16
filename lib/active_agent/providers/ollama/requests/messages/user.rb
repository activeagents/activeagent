# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Ollama
      module Requests
        module Messages
          # User message - messages sent by an end user
          # Ollama has the same user message format as OpenAI
          class User < OpenAI::Chat::Requests::Messages::User
            attribute :images # Array of base64 encoded images
          end
        end
      end
    end
  end
end
