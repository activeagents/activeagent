# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module Anthropic
      class Options < Common::Options
        attribute :base_url,    :string,  default: "https://api.anthropic.com"
        attribute :max_retries, :integer, default: 2
        attribute :timeout,     :float,   default: 600.0

        attribute :api_key,        :string
        attribute :anthropic_beta, :string

        # Common Interface Compatibility
        alias_attribute :access_token, :api_key

        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(kwargs.except(:default_url_options).merge(
            api_key: kwargs[:api_key] || resolve_access_token(kwargs),
          )))
        end

        def to_hash_compressed
          super.except(:anthropic_beta).tap do |hash|
            hash[:extra_headers] = extra_headers unless extra_headers.blank?
          end
        end

        def extra_headers
          deep_compact(
            "anthropic-beta" => anthropic_beta.presence,
          )
        end

        private

        def resolve_access_token(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            anthropic_configuration_access_token ||
            ENV["ANTHROPIC_ACCESS_TOKEN"] ||
            ENV["ANTHROPIC_API_KEY"]
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
