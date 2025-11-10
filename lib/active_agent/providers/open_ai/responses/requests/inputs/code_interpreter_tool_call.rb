# frozen_string_literal: true

require_relative "tool_call_base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Code interpreter tool call - runs Python code
            class CodeInterpreterToolCall < ToolCallBase
              attribute :type, :string, as: "code_interpreter_call"
              attribute :container_id, :string
              attribute :code, :string # Can be null
              attribute :outputs # Always an array of output objects, can be empty

              validates :type, inclusion: { in: %w[code_interpreter_call], allow_nil: false }
              validates :container_id, presence: true
              validates :status, inclusion: {
                in: %w[in_progress completed incomplete interpreting failed],
                allow_nil: false
              }
            end
          end
        end
      end
    end
  end
end
