# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "_types"

module ActiveAgent
  module Providers
    module Anthropic
      class Request < Common::BaseModel
        # Required parameters
        attribute :model,      :string
        attribute :messages,   Requests::Messages::MessagesType.new
        attribute :max_tokens, :integer, fallback: 4096

        # Optional parameters - Prompting
        attribute :system,         Requests::Messages::SystemType.new
        attribute :temperature,    :float
        attribute :top_k,          :integer
        attribute :top_p,          :float
        attribute :stop_sequences, default: -> { [] } # Array of strings

        # Optional parameters - Tools
        attribute :tools       # Array of tool definitions
        attribute :tool_choice, Requests::ToolChoice::ToolChoiceType.new

        # Optional parameters - Thinking
        attribute :thinking, Requests::ThinkingConfig::ThinkingConfigType.new

        # Optional parameters - Streaming
        attribute :stream, :boolean, default: false

        # Optional parameters - Metadata
        attribute :metadata, Requests::MetadataType.new

        # Optional parameters - Context Management
        attribute :context_management, Requests::ContextManagementConfigType.new

        # Optional parameters - Container
        attribute :container, Requests::ContainerParamsType.new

        # Optional parameters - Service tier
        attribute :service_tier, :string

        # Optional parameters - MCP Servers
        attribute :mcp_servers, default: -> { [] } # Array of MCP server definitions

        # Validations for required fields
        validates :model, :messages, :max_tokens, presence: true

        # Validations for numeric parameters
        validates :max_tokens,  numericality: { greater_than_or_equal_to: 1 },                          allow_nil: true
        validates :temperature, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
        validates :top_k,       numericality: { greater_than_or_equal_to: 0 },                           allow_nil: true
        validates :top_p,       numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true

        # Validations for specific values
        validates :service_tier, inclusion: { in: %w[auto standard_only] }, allow_nil: true

        # Custom validations
        validate :validate_stop_sequences
        validate :validate_tools_format
        validate :validate_mcp_servers_format

        # Common Format Compatibility
        alias_attribute :instructions, :system

        # Handle merging in the common format
        def message=(value)
          self.messages ||= []
          self.messages << Requests::Messages::MessageType.new.cast(value)
        end

        private

        def validate_stop_sequences
          return if stop_sequences.nil? || stop_sequences.empty?

          unless stop_sequences.is_a?(Array)
            errors.add(:stop_sequences, "must be an array")
          end
        end

        def validate_tools_format
          return if tools.nil?

          unless tools.is_a?(Array)
            errors.add(:tools, "must be an array")
          end
        end

        def validate_mcp_servers_format
          return if mcp_servers.nil? || mcp_servers.empty?

          unless mcp_servers.is_a?(Array)
            errors.add(:mcp_servers, "must be an array")
            return
          end

          if mcp_servers.length > 20
            errors.add(:mcp_servers, "can have at most 20 servers")
          end
        end
      end
    end
  end
end
