# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Function call output for function tool calls
            class FunctionCallOutput < Base
              attribute :type, :string, as: "function_call_output"
              attribute :id, :string
              attribute :call_id, :string
              attribute :output # Always an array of content, serialized to string if single item
              attribute :status, :string

              validates :type, inclusion: { in: %w[function_call_output], allow_nil: false }
              validates :call_id, presence: true
              validates :output, presence: true
              validates :status, inclusion: {
                in: %w[in_progress completed incomplete],
                allow_nil: true
              }
            end
          end
        end
      end
    end
  end
end
