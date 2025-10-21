# frozen_string_literal: true

require_relative "tool_call_base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Web search tool call - results from web search
            class WebSearchToolCall < ToolCallBase
              attribute :type, :string, as: "web_search_call"
              attribute :action # WebSearchAction object (search, open_page, or find)

              validates :type, inclusion: { in: %w[web_search_call], allow_nil: false }
              validates :action, presence: true
            end
          end
        end
      end
    end
  end
end
