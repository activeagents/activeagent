# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Anthropic
      class Options < Common::BaseModel
        attribute :api_key,  :string
        attribute :base_url, :string,  default: "https://api.anthropic.com"

        attribute :anthropic_beta, :string

        attribute :max_retries,         :integer, default: ::Anthropic::Client::DEFAULT_MAX_RETRIES
        attribute :timeout,             :float,   default: ::Anthropic::Client::DEFAULT_TIMEOUT_IN_SECONDS
        attribute :initial_retry_delay, :float,   default: ::Anthropic::Client::DEFAULT_INITIAL_RETRY_DELAY
        attribute :max_retry_delay,     :float,   default: ::Anthropic::Client::DEFAULT_MAX_RETRY_DELAY

        # Common Interface Compatibility
        alias_attribute :access_token, :api_key

        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(kwargs.except(:default_url_options).merge(
            api_key: kwargs[:api_key] || resolve_access_token(kwargs),
          )))
        end

        def serialize
          super.except(:anthropic_beta)
        end

        # Anthropic gem handles beta headers differently via client.beta
        # rather than via extra_headers in request_options
        def extra_headers
          {}
        end

        private

        def resolve_access_token(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["ANTHROPIC_ACCESS_TOKEN"] ||
            ENV["ANTHROPIC_API_KEY"]
        end
      end
    end
  end
end
