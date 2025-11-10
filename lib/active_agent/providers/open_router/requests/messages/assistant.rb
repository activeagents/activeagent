# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          # Assistant message for OpenRouter API.
          #
          # Extends OpenAI's assistant message with OpenRouter-specific behavior.
          # Drops reasoning fields during message reconstruction since they're not
          # part of the standard request format.
          class Assistant < OpenAI::Chat::Requests::Messages::Assistant
            drop_attributes :reasoning, :reasoning_details
          end
        end
      end
    end
  end
end
