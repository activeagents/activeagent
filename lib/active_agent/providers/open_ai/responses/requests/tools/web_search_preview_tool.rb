# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Web search preview tool (older version)
            class WebSearchPreviewTool < Base
              attribute :type, :string, as: "web_search_preview" # Can be "web_search_preview" or "web_search_preview_2025_03_11"
              attribute :search_context_size, :string # Optional: "low", "medium", or "high"
              attribute :user_location # Hash - optional: { type: "approximate", city, country, region, timezone }

              validates :search_context_size, inclusion: { in: %w[low medium high] }, allow_nil: true
            end
          end
        end
      end
    end
  end
end
