# frozen_string_literal: true

require "active_agent/providers/open_ai/chat/requests/messages/content/files/details"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        module Messages
          module Content
            module Files
              # File details for OpenRouter file attachments
              #
              # Represents the nested file object within a file content part.
              # Unlike OpenAI which strips the data URI prefix (e.g., data:application/pdf;base64,),
              # OpenRouter requires it to be present in the file_data field.
              #
              # @example With data URI
              #   details = Details.new(
              #     file_data: 'data:application/pdf;base64,JVBERi0xLjQK...',
              #     filename: 'report.pdf'
              #   )
              #
              # @see Content::File
              class Details < OpenAI::Chat::Requests::Messages::Content::Files::Details
                # @!attribute file_data
                #   @return [String] file data with data URI prefix intact
                #     Format: "data:<mime-type>;base64,<base64-data>"
                attribute :file_data, :string
              end
            end
          end
        end
      end
    end
  end
end
