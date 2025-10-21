# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # MCP approval request - request for human approval
            class MCPApprovalRequest < Base
              attribute :type, :string, as: "mcp_approval_request"
              attribute :id, :string
              attribute :server_label, :string
              attribute :name, :string
              attribute :arguments, :string # JSON string

              validates :type, inclusion: { in: %w[mcp_approval_request], allow_nil: false }
              validates :id, presence: true
              validates :server_label, presence: true
              validates :name, presence: true
              validates :arguments, presence: true
            end
          end
        end
      end
    end
  end
end
