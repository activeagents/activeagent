# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Built-in web search tool
            class WebSearchTool < Base
              attribute :type, :string, as: "web_search" # Can be "web_search" or "web_search_2025_08_26"
              attribute :filters # Hash - optional: { allowed_domains: [] }
              attribute :search_context_size, :string, default: "medium" # Optional: "low", "medium", or "high"
              attribute :user_location # Hash - optional: { type: "approximate", city, country, region, timezone }

              validates :search_context_size, inclusion: { in: %w[low medium high] }, allow_nil: true
            end
          end
        end
      end
    end
  end
end
