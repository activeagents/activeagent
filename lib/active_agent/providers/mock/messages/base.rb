# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Mock
      module Messages
        # Base class for Mock messages.
        class Base < Common::BaseModel
          attribute :role, :string
          attribute :content

          validates :role, presence: true

          # Define content setter methods for different content types
          %i[text image document].each do |content_type|
            define_method(:"#{content_type}=") do |value|
              # For mock provider, we keep content simple
              # If it's text, just set content to the text value
              if content_type == :text
                self.content = value
              else
                # For image/document, MockProvider doesn't support these, so ignore
                # (or could raise an error)
              end
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

          # Extracts text content from the content structure.
          #
          # @return [String] extracted text content
          def extract_text_content
            case content
            when String
              content
            when Array
              # Join all text blocks
              content.select { |block| block.is_a?(Hash) && block[:type] == "text" }
                     .map { |block| block[:text] }
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
