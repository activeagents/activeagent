require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "azure/_types"

module ActiveAgent
  module Providers
    # Provider for Azure OpenAI Service via OpenAI-compatible API.
    #
    # Azure OpenAI uses the same API structure as OpenAI but with different
    # authentication (api-key header) and endpoint configuration (resource + deployment).
    #
    # @example Configuration in active_agent.yml
    #   azure_openai:
    #     service: "AzureOpenAI"
    #     api_key: <%= ENV["AZURE_OPENAI_API_KEY"] %>
    #     azure_resource: "mycompany"
    #     deployment_id: "gpt-4-deployment"
    #     api_version: "2024-10-21"
    #
    # @see OpenAI::ChatProvider
    class AzureProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "AzureOpenAI"
      end

      # @return [Class]
      def self.options_klass
        Azure::Options
      end

      # @return [ActiveModel::Type::Value]
      def self.prompt_request_type
        OpenAI::Chat::RequestType.new
      end

      # @return [ActiveModel::Type::Value]
      def self.embed_request_type
        OpenAI::Embedding::RequestType.new
      end

      # Returns a configured Azure OpenAI client.
      #
      # Uses a custom client subclass that handles Azure-specific authentication
      # (api-key header instead of Authorization: Bearer).
      #
      # @return [AzureClient] the configured Azure client
      def client
        @client ||= AzureClient.new(
          api_key: options.api_key,
          base_url: options.base_url,
          api_version: options.api_version,
          max_retries: options.max_retries,
          timeout: options.timeout,
          initial_retry_delay: options.initial_retry_delay,
          max_retry_delay: options.max_retry_delay
        )
      end

      # Custom OpenAI client for Azure OpenAI Service.
      #
      # Azure uses different authentication headers (api-key instead of Authorization: Bearer)
      # and requires api-version as a query parameter on all requests.
      class AzureClient < ::OpenAI::Client
        # @return [String]
        attr_reader :api_version

        # Creates a new Azure OpenAI client.
        #
        # @param api_key [String] Azure OpenAI API key
        # @param base_url [String] Azure endpoint URL
        # @param api_version [String] API version (e.g., "2024-10-21")
        # @param max_retries [Integer] Maximum retry attempts
        # @param timeout [Float] Request timeout in seconds
        # @param initial_retry_delay [Float] Initial delay between retries
        # @param max_retry_delay [Float] Maximum delay between retries
        def initialize(
          api_key:,
          base_url:,
          api_version:,
          max_retries: self.class::DEFAULT_MAX_RETRIES,
          timeout: self.class::DEFAULT_TIMEOUT_IN_SECONDS,
          initial_retry_delay: self.class::DEFAULT_INITIAL_RETRY_DELAY,
          max_retry_delay: self.class::DEFAULT_MAX_RETRY_DELAY
        )
          @api_version = api_version

          super(
            api_key: api_key,
            base_url: base_url,
            max_retries: max_retries,
            timeout: timeout,
            initial_retry_delay: initial_retry_delay,
            max_retry_delay: max_retry_delay
          )
        end

        private

        # Azure uses api-key header instead of Authorization: Bearer.
        #
        # @return [Hash{String=>String}]
        def auth_headers
          return {} if @api_key.nil?

          { "api-key" => @api_key }
        end

        # Builds request with Azure-specific query parameters.
        #
        # Injects api-version into extra_query for all requests.
        #
        # @param req [Hash] Request parameters
        # @param opts [Hash] Request options
        # @return [Hash] Built request
        def build_request(req, opts)
          # Inject api-version into extra_query
          opts = opts.dup
          opts[:extra_query] = (opts[:extra_query] || {}).merge("api-version" => @api_version)

          super(req, opts)
        end
      end
    end

    # Aliases for provider loading with different service name variations
    AzureOpenAIProvider = AzureProvider
    AzureOpenaiProvider = AzureProvider
  end
end
