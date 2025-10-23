# frozen_string_literal: true

require "active_agent/providers/common/model"

require_relative "messages/_types"

module ActiveAgent
  module Providers
    module Mock
      # Request model for Mock provider.
      #
      # Simplified request model that accepts messages and basic parameters.
      class Request < Common::BaseModel
        # Required parameters
        attribute :model, :string, default: "mock-model"
        attribute :messages, Messages::MessagesType.new

        # Optional parameters
        attribute :instructions # System instructions
        attribute :temperature, :float
        attribute :max_tokens, :integer
        attribute :stream, :boolean, default: false
        attribute :tools # Array of tool definitions
        attribute :tool_choice # Tool choice configuration

        # Common Format Compatibility
        def message=(value)
          self.messages ||= []
          self.messages << value
        end
      end
    end
  end
end
