# frozen_string_literal: true

require "active_agent/providers/common/model"

require_relative "messages/_types"

module ActiveAgent
  module Providers
    module RubyLLM
      # Request model for RubyLLM provider.
      class Request < Common::BaseModel
        attribute :model, :string
        attribute :messages, Messages::MessagesType.new
        attribute :instructions
        attribute :tools
        attribute :tool_choice
        attribute :temperature, :float
        attribute :max_tokens, :integer
        attribute :stream, :boolean, default: false
        attribute :response_format

        # Common Format Compatibility
        def message=(value)
          self.messages ||= []
          self.messages << value
        end
      end
    end
  end
end
