# frozen_string_literal: true

require_relative "tool_call_base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Image generation tool call
            class ImageGenToolCall < ToolCallBase
              attribute :type, :string, as: "image_generation_call"
              attribute :result, :string # Base64 encoded image or null

              validates :type, inclusion: { in: %w[image_generation_call], allow_nil: false }
              validates :status, inclusion: {
                in: %w[in_progress completed generating failed],
                allow_nil: false
              }
            end
          end
        end
      end
    end
  end
end
