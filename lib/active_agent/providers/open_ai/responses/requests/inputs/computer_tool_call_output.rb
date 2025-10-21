# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Computer tool call output
            class ComputerToolCallOutput < Base
              attribute :type, :string, as: "computer_call_output"
              attribute :id, :string
              attribute :call_id, :string
              attribute :acknowledged_safety_checks # Always an array of safety check objects
              attribute :output # ComputerScreenshotImage object
              attribute :status, :string

              validates :type, inclusion: { in: %w[computer_call_output], allow_nil: false }
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
