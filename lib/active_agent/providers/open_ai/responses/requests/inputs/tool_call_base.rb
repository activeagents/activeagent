# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Base class for all tool call types
            class ToolCallBase < Base
              attribute :id, :string
              attribute :status, :string

              validates :id, presence: true
              validates :status, inclusion: {
                in: %w[in_progress completed incomplete failed searching generating calling interpreting],
                allow_nil: true
              }
            end
          end
        end
      end
    end
  end
end
