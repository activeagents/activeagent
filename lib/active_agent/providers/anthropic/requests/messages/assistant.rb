# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Messages
          # Assistant message - messages sent by the model
          class Assistant < Base
            attribute :role, :string, as: "assistant"

            # Content can be:
            # - A string (shorthand for single text block)
            # - An array of content blocks (text, thinking, tool_use, etc.)
            validates :content, presence: true

            drop_attributes :usage, :id, :model, :stop_reason, :stop_sequence, :type
          end
        end
      end
    end
  end
end
