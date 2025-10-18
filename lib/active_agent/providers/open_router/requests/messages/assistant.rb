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
            # Drops reasoning attribute during message reconstruction.
            # @param value [String] reasoning value to ignore
            def reasoning=(value); end

            # Drops reasoning_details attribute during message reconstruction.
            # @param value [Hash] reasoning_details value to ignore
            def reasoning_details=(value); end
          end
        end
      end
    end
  end
end
