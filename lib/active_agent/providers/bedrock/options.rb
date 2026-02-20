# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Bedrock
      # Configuration for AWS Bedrock provider.
      #
      # AWS credentials are resolved in order:
      # 1. Explicit options (aws_access_key, aws_secret_key)
      # 2. Environment variables (AWS_REGION, AWS_ACCESS_KEY_ID, etc.)
      # 3. AWS SDK default chain (profiles, IAM roles, instance metadata)
      #
      # Unlike the Anthropic provider, no API key is needed — authentication
      # is handled entirely through AWS credentials.
      #
      # @example Minimal config (uses SDK default chain)
      #   Bedrock::Options.new(aws_region: "eu-west-2")
      #
      # @example Explicit credentials
      #   Bedrock::Options.new(
      #     aws_region: "eu-west-2",
      #     aws_access_key: "AKIA...",
      #     aws_secret_key: "..."
      #   )
      #
      # @example With profile
      #   Bedrock::Options.new(
      #     aws_region: "eu-west-2",
      #     aws_profile: "my-profile"
      #   )
      class Options < Common::BaseModel
        attribute :aws_region,        :string
        attribute :aws_access_key,    :string
        attribute :aws_secret_key,    :string
        attribute :aws_session_token, :string
        attribute :aws_profile,       :string
        attribute :aws_bearer_token,  :string
        attribute :base_url,          :string
        attribute :anthropic_beta,    :string

        attribute :max_retries,         :integer, default: ::Anthropic::Client::DEFAULT_MAX_RETRIES
        attribute :timeout,             :float,   default: ::Anthropic::Client::DEFAULT_TIMEOUT_IN_SECONDS
        attribute :initial_retry_delay, :float,   default: ::Anthropic::Client::DEFAULT_INITIAL_RETRY_DELAY
        attribute :max_retry_delay,     :float,   default: ::Anthropic::Client::DEFAULT_MAX_RETRY_DELAY

        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(kwargs.except(:default_url_options).merge(
            aws_region:        kwargs[:aws_region]        || ENV["AWS_REGION"] || ENV["AWS_DEFAULT_REGION"],
            aws_access_key:    kwargs[:aws_access_key]    || ENV["AWS_ACCESS_KEY_ID"],
            aws_secret_key:    kwargs[:aws_secret_key]    || ENV["AWS_SECRET_ACCESS_KEY"],
            aws_session_token: kwargs[:aws_session_token] || ENV["AWS_SESSION_TOKEN"],
            aws_profile:       kwargs[:aws_profile]       || ENV["AWS_PROFILE"],
            aws_bearer_token:  kwargs[:aws_bearer_token]  || ENV["AWS_BEARER_TOKEN_BEDROCK"]
          )))
        end

        # Bedrock handles authentication at the client level (SigV4 or bearer token),
        # so no extra headers are needed in request options.
        def extra_headers
          {}
        end

        # Excludes sensitive AWS credentials from serialized output.
        # The provider's client() method reads credentials directly from options attributes.
        def serialize
          attributes.symbolize_keys.except(
            :aws_access_key, :aws_secret_key, :aws_session_token, :aws_profile, :aws_bearer_token
          )
        end
      end
    end
  end
end
