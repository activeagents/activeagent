# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          class WebSearchOptions < Common::BaseModel
            # Search context size (low, medium, high)
            attribute :search_context_size, :string

            # User location for search
            attribute :user_location # Hash with type and approximate

            validates :search_context_size, inclusion: { in: %w[low medium high] }, allow_nil: true

            # Validate user_location format
            validate :validate_user_location_format

            private

            def validate_user_location_format
              return if user_location.nil?

              unless user_location.is_a?(Hash)
                errors.add(:user_location, "must be a hash")
                return
              end

              unless user_location[:type] == "approximate"
                errors.add(:user_location, "type must be 'approximate'")
              end

              unless user_location[:approximate].is_a?(Hash)
                errors.add(:user_location, "must include 'approximate' hash")
              end
            end
          end
        end
      end
    end
  end
end
