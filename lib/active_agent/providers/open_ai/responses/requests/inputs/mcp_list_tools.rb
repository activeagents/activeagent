# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # MCP list tools - list of tools available on an MCP server
            class MCPListTools < Base
              attribute :type, :string, as: "mcp_list_tools"
              attribute :id, :string
              attribute :server_label, :string
              attribute :tools # Always an array of tool objects
              attribute :error, :string # Error message if listing failed

              validates :type, inclusion: { in: %w[mcp_list_tools], allow_nil: false }
              validates :id, presence: true
              validates :server_label, presence: true
              validates :tools, presence: true
            end
          end
        end
      end
    end
  end
end
