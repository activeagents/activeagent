# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # MCP (Model Context Protocol) tool
            class McpTool < Base
              attribute :type, :string, as: "mcp"
              attribute :server_label, :string # Required: label for this MCP server
              attribute :allowed_tools # Optional: array of tool names or filter object
              attribute :authorization, :string # Optional: OAuth access token
              attribute :connector_id, :string # Optional: service connector ID (e.g., "connector_googledrive")
              attribute :headers # Optional: hash of HTTP headers
              attribute :require_approval # Optional: string ("always"/"never") or object with approval filters
              attribute :server_description, :string # Optional: description of the MCP server
              attribute :server_url, :string # Optional: URL for the MCP server

              validates :server_label, presence: true

              # Either server_url or connector_id must be provided
              validate :validate_server_url_or_connector_id

              private

              def validate_server_url_or_connector_id
                if server_url.blank? && connector_id.blank?
                  errors.add(:base, "Either server_url or connector_id must be provided")
                end
              end
            end
          end
        end
      end
    end
  end
end
