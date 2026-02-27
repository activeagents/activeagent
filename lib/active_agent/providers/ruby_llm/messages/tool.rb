# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module RubyLLM
      module Messages
        # Tool result message for RubyLLM provider.
        class Tool < Base
          attribute :role, :string, as: "tool"
          attribute :content
          attribute :tool_call_id, :string

          def to_common
            common = super
            common[:tool_call_id] = tool_call_id if tool_call_id
            common
          end
        end
      end
    end
  end
end
