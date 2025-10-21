# frozen_string_literal: true

require_relative "tool_call_base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Function tool call - function calling
            class FunctionToolCall < ToolCallBase
              attribute :type, :string, as: "function_call"
              attribute :call_id, :string
              attribute :name, :string
              attribute :arguments, :string # JSON string

              validates :type, inclusion: { in: %w[function_call], allow_nil: false }
              validates :call_id, presence: true
              validates :name, presence: true
              validates :arguments, presence: true
            end
          end
        end
      end
    end
  end
end
