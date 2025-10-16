# frozen_string_literal: true

require_relative "../common/options"

module ActiveAgent
  module Providers
    module OpenAI
      class Options < Common::Options
        attribute :access_token,    :string
        attribute :uri_base,        :string
        attribute :request_timeout, :integer
        attribute :organization_id, :string
        attribute :admin_token,     :string
        attribute :log_errors,      :boolean, default: false

        validates :access_token, presence: true

        # Backwards Compatibility
        alias_attribute :host,    :uri_base
        alias_attribute :api_key, :access_token

        # Initialize from a hash (kwargs) with fallback to environment variables and OpenAI gem configuration
        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(kwargs.except(:default_url_options).merge(
            access_token:    kwargs[:access_token]    || resolve_access_token(kwargs),
            admin_token:     kwargs[:admin_token]     || resolve_admin_token(kwargs),
            log_errors:      kwargs[:log_errors]      || resolve_log_errors(kwargs),
            organization_id: kwargs[:organization_id] || resolve_organization_id(kwargs),
          )))
        end

        private

        def resolve_access_token(kwargs)
          kwargs[:api_key] ||
            openai_configuration_access_token ||
            ENV["OPENAI_ACCESS_TOKEN"] ||
            ENV["OPEN_AI_ACCESS_TOKEN"]
        end

        def resolve_admin_token(kwargs)
            openai_configuration_admin_token ||
            ENV["OPENAI_ADMIN_TOKEN"] ||
            ENV["OPEN_AI_ADMIN_TOKEN"]
        end

        def resolve_log_errors(kwargs)
          return nil unless defined?(::Rails)
          ::Rails.env.local?
        rescue
          nil
        end

        def resolve_organization_id(kwargs)
            openai_configuration_organization_id ||
            ENV["OPENAI_ORGANIZATION_ID"] ||
            ENV["OPEN_AI_ORGANIZATION_ID"]
        end


        def openai_configuration_access_token
          return nil unless defined?(::OpenAI)
          ::OpenAI.configuration.access_token
        rescue
          nil
        end

        def openai_configuration_organization_id
          return nil unless defined?(::OpenAI)
          ::OpenAI.configuration.organization_id
        rescue
          nil
        end

        def openai_configuration_admin_token
          return nil unless defined?(::OpenAI)
          ::OpenAI.configuration.admin_token
        rescue
          nil
        end
      end
    end
  end
end
