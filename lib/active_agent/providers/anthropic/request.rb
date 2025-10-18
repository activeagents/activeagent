# frozen_string_literal: true

require_relative "../common/_base_model"
require_relative "requests/types"
require_relative "requests/metadata"
require_relative "requests/thinking_config"
require_relative "requests/tool_choice"
require_relative "requests/context_management_config"
require_relative "requests/container_params"
require_relative "requests/message"

module ActiveAgent
  module Providers
    module Anthropic
      class Request < Common::BaseModel
        # Required parameters
        attribute :model,      :string
        attribute :messages,   Requests::Types::MessagesType.new
        attribute :max_tokens, :integer

        # Optional parameters - Prompting
        attribute :system,         Requests::Types::SystemType.new
        attribute :temperature,    :float
        attribute :top_k,          :integer
        attribute :top_p,          :float
        attribute :stop_sequences, default: -> { [] } # Array of strings

        # Optional parameters - Tools
        attribute :tools       # Array of tool definitions
        attribute :tool_choice, Requests::Types::ToolChoiceType.new

        # Optional parameters - Thinking
        attribute :thinking, Requests::Types::ThinkingConfigType.new

        # Optional parameters - Streaming
        attribute :stream, :boolean, default: false

        # Optional parameters - Metadata
        attribute :metadata, Requests::Types::MetadataType.new

        # Optional parameters - Context Management
        attribute :context_management, Requests::Types::ContextManagementConfigType.new

        # Optional parameters - Container
        attribute :container, Requests::Types::ContainerParamsType.new

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

        def to_hash_compressed
          super.tap do |hash|
            hash[:system] = hash[:system].first[:text] if hash[:system]&.one?
          end
        end

        # Handle message assignment from common format
        def message=(value)
          self.messages ||= []

          self.messages << {
            role:    value.role,
            content: value.content
          }
        end

        # Handle multiple messages assignment
        def messages=(value)
          case value
          when Array
            super(value)
          else
            super([ value ])
          end
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
