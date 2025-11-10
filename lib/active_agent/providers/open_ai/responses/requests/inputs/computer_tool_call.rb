# frozen_string_literal: true

require_relative "tool_call_base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Computer tool call - computer use tool
            class ComputerToolCall < ToolCallBase
              attribute :type, :string, as: "computer_call"
              attribute :call_id, :string
              attribute :action # ComputerAction object
              attribute :pending_safety_checks # Always an array of safety check objects

              validates :type, inclusion: { in: %w[computer_call], allow_nil: false }
              validates :call_id, presence: true
              validates :action, presence: true
              validates :pending_safety_checks, presence: true
            end
          end
        end
      end
    end
  end
end
