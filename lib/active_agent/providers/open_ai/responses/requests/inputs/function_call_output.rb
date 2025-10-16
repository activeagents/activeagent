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
              attribute :call_id, :string
              attribute :output, :string # Can be string or array

              validates :call_id, presence: true
              validates :output, presence: true
            end
          end
        end
      end
    end
  end
end
