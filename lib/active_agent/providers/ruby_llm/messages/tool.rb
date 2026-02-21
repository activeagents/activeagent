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
        end
      end
    end
  end
end
