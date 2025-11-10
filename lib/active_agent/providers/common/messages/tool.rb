# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Common
      module Messages
        # Tool message - messages containing tool call results
        class Tool < Base
          attribute :role, :string, as: "tool"
          attribute :content, :string # Tool result content
          attribute :tool_call_id, :string # ID of the tool call this is responding to
          attribute :name, :string # Optional name of the tool

          validates :content, presence: true
        end
      end
    end
  end
end
