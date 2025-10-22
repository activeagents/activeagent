# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "messages/base"
require_relative "messages/user"
require_relative "messages/assistant"

module ActiveAgent
  module Providers
    module Mock
      # Type for Messages array
      class MessagesType < ActiveModel::Type::Value
        def cast(value)
          return [] if value.nil?
          return value if value.is_a?(Array) && value.all? { |v| v.is_a?(Messages::Base) }

          Array(value).map { |msg| cast_message(msg) }.compact
        end

        def serialize(value)
          Array(value).map do |msg|
            msg.respond_to?(:serialize) ? msg.serialize : msg
          end
        end

        private

        def cast_message(value)
          case value
          when Messages::Base
            value
          when String
            # Convert bare strings to user message hashes
            { role: "user", content: value }
          when Hash
            hash = value.deep_symbolize_keys
            role = hash[:role]&.to_s

            case role
            when "assistant"
              Messages::Assistant.new(**hash)
            when "user", nil
              # Handle both standard format and format with `text` key
              if hash[:text] && !hash[:content]
                Messages::User.new(role: "user", content: hash[:text])
              else
                Messages::User.new(**hash.merge(role: "user"))
              end
            else
              # Pass through other roles as-is
              hash
            end
          else
            value
          end
        end
      end

      # Request model for Mock provider.
      #
      # Simplified request model that accepts messages and basic parameters.
      class Request < Common::BaseModel
        # Required parameters
        attribute :model, :string, default: "mock-model"
        attribute :messages, MessagesType.new

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
