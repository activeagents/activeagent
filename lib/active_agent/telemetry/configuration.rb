# frozen_string_literal: true

module ActiveAgent
  module Telemetry
    # Configuration for telemetry collection and reporting.
    #
    # Stores settings for endpoint, authentication, sampling, and batching.
    # Configuration can be set programmatically or loaded from YAML.
    #
    # @example Programmatic configuration
    #   ActiveAgent::Telemetry.configure do |config|
    #     config.enabled = true
    #     config.endpoint = "https://api.activeagents.ai/v1/traces"
    #     config.api_key = "your-api-key"
    #     config.sample_rate = 1.0
    #   end
    #
    # @example YAML configuration (config/activeagent.yml)
    #   telemetry:
    #     enabled: true
    #     endpoint: https://api.activeagents.ai/v1/traces
    #     api_key: <%= ENV["ACTIVEAGENTS_API_KEY"] %>
    #     sample_rate: 1.0
    #     batch_size: 100
    #     flush_interval: 5
    #
    class Configuration
      # @return [Boolean] Whether telemetry is enabled (default: false)
      attr_accessor :enabled

      # @return [String] The endpoint URL for sending traces
      attr_accessor :endpoint

      # @return [String] API key for authentication
      attr_accessor :api_key

      # @return [Float] Sampling rate from 0.0 to 1.0 (default: 1.0)
      attr_accessor :sample_rate

      # @return [Integer] Number of traces to batch before sending (default: 100)
      attr_accessor :batch_size

      # @return [Integer] Seconds between automatic flushes (default: 5)
      attr_accessor :flush_interval

      # @return [Integer] HTTP timeout in seconds (default: 10)
      attr_accessor :timeout

      # @return [Boolean] Whether to capture request/response bodies (default: false)
      attr_accessor :capture_bodies

      # @return [Array<String>] Attributes to redact from traces
      attr_accessor :redact_attributes

      # @return [String] Service name for trace attribution
      attr_accessor :service_name

      # @return [String] Environment name (development, staging, production)
      attr_accessor :environment

      # @return [Hash] Additional resource attributes to include in all traces
      attr_accessor :resource_attributes

      # @return [Logger] Logger for telemetry operations
      attr_accessor :logger

      # @return [Boolean] Whether to store traces locally in the app's database
      attr_accessor :local_storage

      # Default ActiveAgents.ai endpoint for hosted observability.
      DEFAULT_ENDPOINT = "https://api.activeagents.ai/v1/traces"

      # Local dashboard endpoint path (relative to app root)
      LOCAL_ENDPOINT_PATH = "/active_agent/api/traces"

      def initialize
        @enabled = false
        @endpoint = DEFAULT_ENDPOINT
        @api_key = nil
        @sample_rate = 1.0
        @batch_size = 100
        @flush_interval = 5
        @timeout = 10
        @capture_bodies = false
        @redact_attributes = %w[password secret token key credential api_key]
        @service_name = nil
        @environment = Rails.env if defined?(Rails)
        @resource_attributes = {}
        @logger = nil
        @local_storage = false
      end

      # Returns whether telemetry collection is enabled.
      #
      # @return [Boolean]
      def enabled?
        @enabled == true
      end

      # Returns whether telemetry is properly configured.
      #
      # Checks that endpoint and api_key are present, or local_storage is enabled.
      #
      # @return [Boolean]
      def configured?
        local_storage? || (endpoint.present? && api_key.present?)
      end

      # Returns whether local storage mode is enabled.
      #
      # @return [Boolean]
      def local_storage?
        @local_storage == true
      end

      # Returns the resolved endpoint for trace reporting.
      #
      # Uses local endpoint when local_storage is enabled.
      #
      # @return [String]
      def resolved_endpoint
        if local_storage?
          LOCAL_ENDPOINT_PATH
        else
          endpoint
        end
      end

      # Returns whether a trace should be sampled.
      #
      # Uses sample_rate to determine if trace should be collected.
      #
      # @return [Boolean]
      def should_sample?
        return true if sample_rate >= 1.0
        return false if sample_rate <= 0.0

        rand < sample_rate
      end

      # Resolves the service name for traces.
      #
      # Falls back to Rails application name or "activeagent".
      #
      # @return [String]
      def resolved_service_name
        @service_name || rails_app_name || "activeagent"
      end

      # Returns the logger for telemetry operations.
      #
      # Falls back to Rails.logger or a null logger.
      #
      # @return [Logger]
      def resolved_logger
        @logger || (defined?(Rails) && Rails.logger) || Logger.new(File::NULL)
      end

      # Loads configuration from a hash (typically from YAML).
      #
      # @param hash [Hash] Configuration hash
      # @return [self]
      def load_from_hash(hash)
        hash = hash.with_indifferent_access if hash.respond_to?(:with_indifferent_access)

        @enabled = hash[:enabled] if hash.key?(:enabled)
        @endpoint = hash[:endpoint] if hash.key?(:endpoint)
        @api_key = hash[:api_key] if hash.key?(:api_key)
        @sample_rate = hash[:sample_rate].to_f if hash.key?(:sample_rate)
        @batch_size = hash[:batch_size].to_i if hash.key?(:batch_size)
        @flush_interval = hash[:flush_interval].to_i if hash.key?(:flush_interval)
        @timeout = hash[:timeout].to_i if hash.key?(:timeout)
        @capture_bodies = hash[:capture_bodies] if hash.key?(:capture_bodies)
        @redact_attributes = hash[:redact_attributes] if hash.key?(:redact_attributes)
        @service_name = hash[:service_name] if hash.key?(:service_name)
        @environment = hash[:environment] if hash.key?(:environment)
        @resource_attributes = hash[:resource_attributes] if hash.key?(:resource_attributes)
        @local_storage = hash[:local_storage] if hash.key?(:local_storage)

        self
      end

      # Returns configuration as a hash for serialization.
      #
      # @return [Hash]
      def to_h
        {
          enabled: enabled,
          endpoint: endpoint,
          api_key: api_key ? "[REDACTED]" : nil,
          sample_rate: sample_rate,
          batch_size: batch_size,
          flush_interval: flush_interval,
          timeout: timeout,
          capture_bodies: capture_bodies,
          service_name: resolved_service_name,
          environment: environment,
          local_storage: local_storage
        }
      end

      private

      def rails_app_name
        return nil unless defined?(Rails) && Rails.application

        Rails.application.class.module_parent_name.underscore
      rescue StandardError
        nil
      end
    end
  end
end
