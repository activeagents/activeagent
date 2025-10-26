# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      class Options < Common::BaseModel
        attribute :api_key,         :string
        attribute :organization,    :string # Organization ID
        attribute :project,         :string # Project ID ,
        attribute :webhook_secret,  :string
        attribute :base_url,        :string

        attribute :max_retries,         :integer, default: ::OpenAI::Client::DEFAULT_MAX_RETRIES
        attribute :timeout,             :float,   default: ::OpenAI::Client::DEFAULT_TIMEOUT_IN_SECONDS
        attribute :initial_retry_delay, :float,   default: ::OpenAI::Client::DEFAULT_INITIAL_RETRY_DELAY
        attribute :max_retry_delay,     :float,   default: ::OpenAI::Client::DEFAULT_MAX_RETRY_DELAY

        validates :api_key, presence: true

        # Backwards Compatibility
        alias_attribute :host,            :base_url
        alias_attribute :uri_base,        :base_url
        alias_attribute :organization_id, :organization
        alias_attribute :project_id,      :project
        alias_attribute :access_token,    :api_key
        alias_attribute :request_timeout, :timeout

        # Initialize from a hash (kwargs) with fallback to environment variables and OpenAI gem configuration
        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(kwargs.except(:default_url_options).merge(
            api_key:         resolve_api_key(kwargs),
            organization_id: resolve_organization_id(kwargs),
            project_id:      resolve_project_id(kwargs),
          )))
        end

        def extra_headers
          {}
        end

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["OPENAI_API_KEY"] ||
            ENV["OPEN_AI_API_KEY"] ||
            ENV["OPENAI_ACCESS_TOKEN"] ||
            ENV["OPEN_AI_ACCESS_TOKEN"]
        end

        def resolve_organization_id(kwargs)
          kwargs[:organization] ||
            kwargs[:organization_id] ||
            ENV["OPENAI_ORG_ID"] ||
            ENV["OPEN_AI_ORG_ID"] ||
            ENV["OPENAI_ORGANIZATION_ID"] ||
            ENV["OPEN_AI_ORGANIZATION_ID"]
        end

        def resolve_project_id(kwargs)
          kwargs[:project] ||
            kwargs[:project_id]
            ENV["OPENAI_PROJECT_ID"] ||
            ENV["OPEN_AI_PROJECT_ID"]
        end
      end
    end
  end
end
