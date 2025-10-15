# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Chat
        class Prediction < Common::BaseModel
          # Type of predicted content (always "content")
          attribute :type, :string, default: "content"

          # Content that should be matched (string or array of content parts)
          attribute :content

          validates :type, inclusion: { in: %w[content] }, allow_nil: true

          # Validate content is present and in correct format
          validate :validate_content_format

          private

          def validate_content_format
            if content.blank?
              errors.add(:content, "must be present")
              return
            end

            # Content can be a string or an array of content parts
            if content.is_a?(Array)
              content.each do |part|
                unless part.is_a?(Hash) && part[:type].present?
                  errors.add(:content, "array elements must be hashes with a 'type' field")
                end
              end
            elsif !content.is_a?(String)
              errors.add(:content, "must be a string or array of content parts")
            end
          end
        end
      end
    end
  end
end
