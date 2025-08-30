# frozen_string_literal: true

module ActiveSupervisorClient
  class Configuration
    attr_accessor :api_key, :endpoint, :mode, :enabled, :environment,
                  :application_name, :batch_size, :flush_interval,
                  :timeout, :retry_count, :ssl_verify, :debug,
                  :async, :queue_max_size, :thread_count,
                  :sample_rate, :ignored_agents, :ignored_actions,
                  :pii_masking, :error_handler

    def initialize
      # Deployment mode
      @mode = :cloud  # :cloud or :self_hosted
      @endpoint = ENV["ACTIVE_SUPERVISOR_ENDPOINT"] || "https://api.activeagents.ai"
      @api_key = ENV["ACTIVE_SUPERVISOR_API_KEY"]
      
      # Environment
      @enabled = true
      @environment = ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      @application_name = ENV["APP_NAME"] || Rails.application.class.module_parent_name rescue "Unknown"
      
      # Performance
      @batch_size = 100
      @flush_interval = 60  # seconds
      @timeout = 5  # seconds
      @retry_count = 3
      @async = true
      @queue_max_size = 10_000
      @thread_count = 2
      
      # Sampling
      @sample_rate = 1.0  # 100% sampling by default
      
      # Filtering
      @ignored_agents = []
      @ignored_actions = []
      
      # Security
      @ssl_verify = true
      @pii_masking = true
      
      # Debugging
      @debug = false
      @error_handler = ->(error) { Rails.logger.error "[ActiveSupervisor] #{error.message}" }
    end

    def cloud?
      mode == :cloud
    end

    def self_hosted?
      mode == :self_hosted
    end

    def valid?
      return false unless enabled
      return false if cloud? && api_key.blank?
      return false if endpoint.blank?
      true
    end

    def to_h
      {
        mode: mode,
        endpoint: endpoint,
        environment: environment,
        application_name: application_name,
        enabled: enabled,
        async: async,
        sample_rate: sample_rate
      }
    end
  end
end