# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module Anthropic
      class Options < Common::Options
        # Client Options
        attribute :access_token,   :string
        attribute :anthropic_beta, :string

        # Prompt Options
        attribute :max_tokens,     :integer, default: 4096
        attribute :stop_sequences,           default: -> { [] }
        attribute :temperature,    :float
        attribute :top_k,          :integer
        attribute :top_p,          :float
        attribute :stream,         :boolean
        attribute :system # String or array of system message blocks
        attribute :container,      :string
        attribute :service_tier,   :string

        # Tools and tool calling
        attribute :tools # Array of tool definitions
        attribute :tool_choice # String or hash

        # Metadata and user tracking
        attribute :metadata # Hash with user_id, etc.

        # Extended thinking configuration
        attribute :thinking # Hash with type and budget_tokens

        # Context management
        attribute :context_management # Hash with edits configuration

        # MCP servers
        attribute :mcp_servers # Array of MCP server definitions

        # Validations
        validates :access_token, :max_tokens, presence: true
        validates :max_tokens,   numericality: { greater_than_or_equal_to: 1 },                           allow_nil: true
        validates :temperature,  numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
        validates :top_k,        numericality: { greater_than_or_equal_to: 0 },                           allow_nil: true
        validates :top_p,        numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
        validates :service_tier, inclusion: { in: %w[auto standard_only] },                               allow_nil: true

        # Backwards Compatibility
        alias_attribute :api_key, :access_token

        # Initialize from a hash (settings) with fallback to environment variables and OpenAI gem configuration
        def initialize(**settings)
          settings = settings.deep_symbolize_keys if settings.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(settings.except(:default_url_options).merge(
            access_token: settings[:access_token] || resolve_access_token(settings),
          )))
        end

        # Returns a hash suitable for Client initialization
        def client_options
          deep_compact(
            access_token:,
            uri_base:,
            organization_id:,
            extra_headers: client_options_extra_headers,
            log_errors: true
          )
        end

        def client_options_extra_headers
          deep_compact(
            "anthropic-beta".to_sym => anthropic_beta
          )
        end

        # Returns parameters for message requests
        def prompt_parameters
          deep_compact(
            max_tokens:,
            temperature:,
            top_k:,
            top_p:,
            stop_sequences:,
            system:,
            container:,
            service_tier:,
            tools:,
            tool_choice:,
            metadata:,
            thinking:,
            context_management:,
            mcp_servers:
          )
        end

        private

        def resolve_access_token(settings)
          settings["api_key"] ||
            settings["access_token"] ||
            anthropic_configuration_access_token ||
            ENV["ANTHROPIC_ACCESS_TOKEN"]
        end

        def anthropic_configuration_access_token
          return nil unless defined?(::Anthropic)
          ::Anthropic.configuration.access_token
        rescue
          nil
        end
      end
    end
  end
end
