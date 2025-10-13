# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module GenerationProvider
    module Anthropic
      class Options < Common::Options
        # Client Options
        attribute :access_token,     :string
        attribute :anthropic_beta, :string

        # Prompting Options
        attribute :model,        :string

        validates :model,        presence: true
        validates :access_token, presence: true

        # Backwards Compatibility
        alias_attribute :api_key,    :access_token
        alias_attribute :model_name, :model

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
            'anthropic-beta'.to_sym => anthropic_beta
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
