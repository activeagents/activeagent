# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "content/_types"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Messages
          # Base class for Anthropic messages.
          #
          # Provides common message structure and conversion utilities for
          # Anthropic's message format, including content extraction.
          class Base < Common::BaseModel
            attribute :role, :string
            attribute :content, Content::ContentsType.new

            validates :role, presence: true, inclusion: { in: %w[user assistant] }

            # Define content setter methods for different content types
            %i[text image document].each do |content_type|
              define_method(:"#{content_type}=") do |value|
                self.content ||= []
                self.content += [ { content_type => value } ]
              end
            end

            # Converts to common format.
            #
            # @return [Hash] message in canonical format with role and text content
            def to_common
              {
                role: role,
                content: extract_text_content,
                name: nil
              }
            end

            private

            # Extracts text content from Anthropic's content structure.
            #
            # @return [String] extracted text content
            def extract_text_content
              case content
              when String
                content
              when Array
                # Join all text blocks
                content.select { |block| block.type == "text" }
                       .map(&:text)
                       .join("\n")
              else
                content.to_s
              end
            end
          end
        end
      end
    end
  end
end
