# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # MCP approval response - response to approval request
            class MCPApprovalResponse < Base
              attribute :type, :string, as: "mcp_approval_response"
              attribute :id, :string
              attribute :approval_request_id, :string
              attribute :approve, :boolean
              attribute :reason, :string

              validates :type, inclusion: { in: %w[mcp_approval_response], allow_nil: false }
              validates :approval_request_id, presence: true
              validates :approve, inclusion: { in: [ true, false ], allow_nil: false }
            end
          end
        end
      end
    end
  end
end
