# frozen_string_literal: true

require_relative "../../../common/_base_model"

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
            attribute :content, Types::ContentType.new # Can be string or array of content blocks

            validates :role, presence: true, inclusion: { in: %w[user assistant] }

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

            # Converts to hash with compressed content format.
            #
            # Simplifies single text content blocks to plain strings.
            #
            # @return [Hash] hash representation with compressed content
            def to_hash_compressed
              super.tap do |hash|
                # If there is a only a single text we can compress down to a string
                if content.is_a?(Array) && content.one? && content.first.type == "text"
                  hash[:content] = content.first.text
                end
              end
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
