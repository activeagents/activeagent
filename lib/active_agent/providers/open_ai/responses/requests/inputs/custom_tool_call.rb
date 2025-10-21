# frozen_string_literal: true

require_relative "tool_call_base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Custom tool call - call to custom tool
            class CustomToolCall < ToolCallBase
              attribute :type, :string, as: "custom_tool_call"
              attribute :call_id, :string
              attribute :name, :string
              attribute :input, :string # JSON input

              validates :type, inclusion: { in: %w[custom_tool_call], allow_nil: false }
              validates :call_id, presence: true
              validates :name, presence: true
              validates :input, presence: true
            end
          end
        end
      end
    end
  end
end
