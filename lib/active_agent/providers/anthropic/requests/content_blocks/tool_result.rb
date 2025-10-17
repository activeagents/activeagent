# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ContentBlocks
          # Tool result content block
          class ToolResult < Base
            attribute :type, :string, as: "tool_result"
            attribute :tool_use_id, :string
            attribute :content # String or array of content blocks
            attribute :is_error, :boolean
            attribute :cache_control # Optional cache control

            validates :tool_use_id, presence: true, format: { with: /\A[a-zA-Z0-9_-]+\z/ }
          end
        end
      end
    end
  end
end
