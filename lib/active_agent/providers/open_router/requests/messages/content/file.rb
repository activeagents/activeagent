# frozen_string_literal: true

require "active_agent/providers/open_ai/chat/requests/messages/content/base"
require_relative "files/_types"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          module Content
            # File content part for OpenRouter.
            #
            # Uses OpenRouter's Files::DetailsType which preserves the data URI prefix
            # instead of stripping it like OpenAI does.
            class File < OpenAI::Chat::Requests::Messages::Content::Base
              attribute :type, :string, as: "file"
              attribute :file, Files::DetailsType.new

              validates :file, presence: true
            end
          end
        end
      end
    end
  end
end
