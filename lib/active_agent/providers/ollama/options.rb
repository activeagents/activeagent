# frozen_string_literal: true

require_relative "../open_ai/options"
require_relative "../errors"
require_relative "cloud"

module ActiveAgent
  module Providers
    module Ollama
      # Where the provider sends requests and how it signs them.
      #
      # The host is, in order: `host:` (also `base_url:` or `uri_base:`),
      # `cloud: true` for Ollama Cloud, the OLLAMA_HOST variable the ollama
      # command itself reads, and the local server at 127.0.0.1:11434. A bare
      # origin is completed to its OpenAI-compatible /v1 endpoint
      # ({Cloud.normalize_host}). The key is `api_key:` (also
      # `access_token:`), else OLLAMA_API_KEY or OLLAMA_ACCESS_TOKEN, else a
      # placeholder a local server ignores. Ollama Cloud refuses the
      # placeholder, which {#require_cloud_api_key!} reports before a request
      # is made.
      #
      # @example Ollama Cloud
      #   generate_with :ollama, cloud: true, model: "gpt-oss:120b"   # key from OLLAMA_API_KEY
      #
      # @example A local server signed in to the cloud
      #   generate_with :ollama, model: "gpt-oss:120b-cloud"          # no key needed
      class Options < ActiveAgent::Providers::OpenAI::Options
        attribute :base_url, :string, fallback: Cloud::LOCAL_BASE_URL
        attribute :api_key,  :string, fallback: Cloud::PLACEHOLDER_API_KEY
        # Ollama Cloud in one word: requests go to https://ollama.com/v1
        # unless a host is given, and a key is expected.
        attribute :cloud, :boolean

        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(kwargs.except(:host, :uri_base).merge(base_url: resolve_base_url(kwargs)))
        end

        # @return [Boolean] whether requests go to Ollama Cloud
        def cloud?
          cloud == true || Cloud.cloud_host?(base_url)
        end

        # The OpenAI client's options: `cloud` is this provider's alone.
        #
        # @return [Hash]
        def serialize
          super.except(:cloud)
        end

        # Ollama Cloud signs every request with an API key. Raised ahead of
        # the request the cloud would refuse with a 401, naming what to set.
        #
        # @return [void]
        # @raise [Errors::AuthenticationFailed] on the cloud host without a key
        def require_cloud_api_key!
          return unless cloud?
          return if api_key.present? && api_key != Cloud::PLACEHOLDER_API_KEY

          raise Errors::AuthenticationFailed.new(
            "Ollama Cloud (#{base_url}) needs an API key: set OLLAMA_API_KEY, or pass api_key: " \
            "(keys are created at https://ollama.com/settings/keys)",
            provider_tag: "Ollama"
          )
        end

        private

        def resolve_base_url(kwargs)
          explicit = kwargs[:base_url].presence || kwargs[:host].presence || kwargs[:uri_base].presence
          return Cloud.normalize_host(explicit) if explicit
          return Cloud::BASE_URL if ActiveModel::Type::Boolean.new.cast(kwargs[:cloud])

          Cloud.normalize_host(ENV["OLLAMA_HOST"])
        end

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["OLLAMA_API_KEY"] ||
            ENV["OLLAMA_ACCESS_TOKEN"]
        end

        # Not Used as Part of Ollama
        def resolve_organization_id(settings) = nil
        def resolve_project_id(settings)      = nil
      end
    end
  end
end
