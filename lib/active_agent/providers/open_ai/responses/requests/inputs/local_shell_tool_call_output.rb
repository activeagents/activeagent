# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Local shell tool call output
            class LocalShellToolCallOutput < Base
              attribute :type, :string, as: "local_shell_call_output"
              attribute :id, :string
              attribute :call_id, :string
              attribute :output, :string # JSON string output
              attribute :status, :string

              validates :type, inclusion: { in: %w[local_shell_call_output], allow_nil: false }
              validates :id, presence: true
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
