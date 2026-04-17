# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module RubyLLM
      module Messages
        # Base class for RubyLLM messages.
        class Base < Common::BaseModel
          attribute :role, :string
          attribute :content

          validates :role, presence: true

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
