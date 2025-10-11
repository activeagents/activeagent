# frozen_string_literal: true

require_relative "../common/options"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      class Options < Common::Options
        # Client Options
        attribute :access_token,    :string
        attribute :uri_base,        :string
        attribute :request_timeout, :integer
        attribute :organization_id, :string
        attribute :admin_token,     :string

        # Prompting Options
        attribute :model,           :string,  default: "gpt-4o-mini"
        attribute :temperature,     :float,   default: 0.7
        attribute :stream,          :boolean, default: false

        validates :model, presence: true
        validates :temperature, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2 }, allow_nil: true
        validates :access_token, presence: true, if: :require_access_token?

        # Backwards Compatibility
        alias_attribute :host, :uri_base
        alias_attribute :api_key, :access_token
        alias_attribute :model_name, :model

        # Initialize from a hash (settings) with fallback to environment variables and OpenAI gem configuration
        def initialize(**settings)
          settings = settings.deep_symbolize_keys if settings.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(settings.except(:default_url_options).merge(
            access_token:    settings[:access_token]    || resolve_access_token(settings),
            organization_id: settings[:organization_id] || resolve_organization_id(settings),
            admin_token:     settings[:admin_token]     || resolve_admin_token(settings),
          )))
        end

        # Returns a hash suitable for OpenAI::Client initialization
        def client_options
          deep_compact(
            access_token:,
            uri_base:,
            organization_id:,
            extra_headers: client_options_extra_headers,
            log_errors: true
          )
        end

        # Returns parameters for chat completion requests
        def chat_parameters
          deep_compact(
            model:,
            temperature:
          )
        end

        def provider_parameters
          provider.to_h
        end

        protected

        def client_options_extra_headers = nil

        private

        def resolve_access_token(settings)
          settings[:api_key] ||
            openai_settings_access_token ||
            ENV["OPENAI_ACCESS_TOKEN"]
        end

        def resolve_organization_id(settings)
            openai_settings_organization_id ||
            ENV["OPENAI_ORGANIZATION_ID"]
        end

        def resolve_admin_token(settings)
            openai_settings_admin_token ||
            ENV["OPENAI_ADMIN_TOKEN"]
        end

        def openai_settings_access_token
          return nil unless defined?(::OpenAI)
          ::OpenAI.configuration.access_token
        rescue
          nil
        end

        def openai_settings_organization_id
          return nil unless defined?(::OpenAI)
          ::OpenAI.configuration.organization_id
        rescue
          nil
        end

        def openai_settings_admin_token
          return nil unless defined?(::OpenAI)
          ::OpenAI.configuration.admin_token
        rescue
          nil
        end

        # Only require access token if no other authentication method is available
        def require_access_token?
          resolved_access_token.blank?
        end
      end
    end
  end
end
