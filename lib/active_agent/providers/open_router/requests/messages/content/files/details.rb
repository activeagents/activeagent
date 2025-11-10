# frozen_string_literal: true

require "active_agent/providers/open_ai/chat/requests/messages/content/files/details"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          module Content
            module Files
              # Represents the nested file object within File content part for OpenRouter.
              #
              # Unlike OpenAI which strips the data URI prefix, OpenRouter keeps it intact
              # (e.g., data:application/pdf;base64,) in the file_data field.
              class Details < OpenAI::Chat::Requests::Messages::Content::Files::Details
                # Override the setter to NOT strip the data URI prefix
                attribute :file_data, :string
              end
            end
          end
        end
      end
    end
  end
end
