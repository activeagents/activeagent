# frozen_string_literal: true

require_relative "tool_call_base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # MCP tool call - invocation of MCP server tool
            class MCPToolCall < ToolCallBase
              attribute :type, :string, as: "mcp_call"
              attribute :server_label, :string
              attribute :name, :string
              attribute :arguments, :string # JSON string
              attribute :output, :string # JSON output or null
              attribute :error, :string # Error message or null
              attribute :approval_request_id, :string # Optional approval request ID

              validates :type, inclusion: { in: %w[mcp_call], allow_nil: false }
              validates :server_label, presence: true
              validates :name, presence: true
              validates :arguments, presence: true
              validates :status, inclusion: {
                in: %w[in_progress completed incomplete calling failed],
                allow_nil: false
              }
            end
          end
        end
      end
    end
  end
end
