# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Chat
        module Requests
          module Messages
            # Tool message - result from a tool call
            class Tool < Base
              attribute :role, :string, as: "tool"
              attribute :content # String or array of content parts
              attribute :tool_call_id, :string # ID of the tool call this is a response to

              validates :content, presence: true
              validates :tool_call_id, presence: true
            end
          end
        end
      end
    end
  end
end
