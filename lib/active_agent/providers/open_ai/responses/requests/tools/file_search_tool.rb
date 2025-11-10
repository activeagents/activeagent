# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Built-in file search tool
            class FileSearchTool < Base
              attribute :type, :string, as: "file_search"
              attribute :vector_store_ids # Array - required: The IDs of the vector stores to search
              attribute :filters # Hash - optional: A filter to apply
              attribute :max_num_results, :integer # Optional: maximum number of results (1-50)
              attribute :ranking_options # Hash - optional: { ranker: string, score_threshold: number }

              validates :vector_store_ids, presence: true
              validates :max_num_results, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 50 }, allow_nil: true
            end
          end
        end
      end
    end
  end
end
