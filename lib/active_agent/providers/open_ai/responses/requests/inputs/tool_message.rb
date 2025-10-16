# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Tool message input
            class ToolMessage < Base
              attribute :role, :string, as: "tool"
              attribute :tool_call_id, :string

              validates :tool_call_id, presence: true, if: -> { role == "tool" }
            end
          end
        end
      end
    end
  end
end
