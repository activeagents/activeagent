# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Custom tool call output
            class CustomToolCallOutput < Base
              attribute :type, :string, as: "custom_tool_call_output"
              attribute :id, :string
              attribute :call_id, :string
              attribute :output # Always an array of content, serialized to string if single item

              validates :type, inclusion: { in: %w[custom_tool_call_output], allow_nil: false }
              validates :call_id, presence: true
              validates :output, presence: true
            end
          end
        end
      end
    end
  end
end
