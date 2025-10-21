# frozen_string_literal: true

require_relative "tool_call_base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # File search tool call - results from file search
            class FileSearchToolCall < ToolCallBase
              attribute :type, :string, as: "file_search_call"
              attribute :queries # Always an array of strings
              attribute :results # Always an array of result objects, can be empty

              validates :type, inclusion: { in: %w[file_search_call], allow_nil: false }
              validates :queries, presence: true
            end
          end
        end
      end
    end
  end
end
