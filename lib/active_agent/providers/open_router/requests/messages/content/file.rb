# frozen_string_literal: true

require "active_agent/providers/open_ai/chat/requests/messages/content/base"
require_relative "files/_types"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          module Content
            # File content part for OpenRouter messages
            #
            # Represents a file attachment in a message. Unlike OpenAI which strips
            # the data URI prefix, OpenRouter preserves it in the file_data field.
            #
            # @example PDF file attachment
            #   file = File.new(
            #     file: {
            #       file_data: 'data:application/pdf;base64,JVBERi0...',
            #       filename: 'document.pdf'
            #     }
            #   )
            #
            # @see Files::Details
            # @see https://openrouter.ai/docs/file-uploads OpenRouter File Uploads
            class File < OpenAI::Chat::Requests::Messages::Content::Base
              # @!attribute type
              #   @return [String] always "file"
              attribute :type, :string, as: "file"

              # @!attribute file
              #   @return [Files::Details] file details with data URI
              attribute :file, Files::DetailsType.new

              validates :file, presence: true
            end
          end
        end
      end
    end
  end
end
