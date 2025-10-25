# frozen_string_literal: true

require "active_agent/providers/open_ai/chat/requests/messages/user"
require_relative "content/_types"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          # User message for OpenRouter API.
          #
          # Extends OpenAI's user message with OpenRouter-specific content handling.
          # Overrides the content attribute to use OpenRouter's ContentsType which
          # preserves the data URI prefix in file content instead of stripping it.
          class User < OpenAI::Chat::Requests::Messages::User
            attribute :content, Content::ContentsType.new # Override with OpenRouter's content handling

            %i[text image document].each do |content_type|
              define_method(:"#{content_type}=") do |value|
                self.content ||= []
                self.content += [ { content_type => value } ]
              end
            end
          end
        end
      end
    end
  end
end
