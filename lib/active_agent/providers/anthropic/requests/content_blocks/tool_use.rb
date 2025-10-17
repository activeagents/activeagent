# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ContentBlocks
          # Tool use content block
          class ToolUse < Base
            attribute :type, :string, as: "tool_use"
            attribute :id, :string
            attribute :name, :string
            attribute :input # Object containing tool input
            attribute :cache_control # Optional cache control

            validates :id, presence: true, format: { with: /\A[a-zA-Z0-9_-]+\z/ }
            validates :name, presence: true, length: { minimum: 1, maximum: 200 }
            validates :input, presence: true

            # To drop the field during message reconstruction
            def json_buf=(value); end
          end
        end
      end
    end
  end
end
