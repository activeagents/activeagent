# frozen_string_literal: true

require "active_agent/providers/common/model"
require "active_agent/providers/common/messages/_types"

require_relative "messages/base"
require_relative "messages/user"
require_relative "messages/assistant"

module ActiveAgent
  module Providers
    module Mock
      # Request model for Mock provider.
      #
      # Simplified request model that accepts messages and basic parameters.
      class Request < Common::BaseModel
        # Required parameters
        attribute :model, :string, default: "mock-model"
        attribute :messages, Common::Messages::Types::MessagesType.new

        # Optional parameters
        attribute :instructions # System instructions (ignored by mock but accepted for compatibility)
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
