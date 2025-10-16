# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          # Assistant message - messages sent by the model
          # Inherits from OpenAI base as OpenRouter is largely compatible
          class Assistant < OpenAI::Chat::Requests::Messages::Assistant
            # This is to drop reasoning during the construction of callback messaging
            def reasoning=(value); end
          end
        end
      end
    end
  end
end
