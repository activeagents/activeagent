# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Logging
      extend ActiveSupport::Concern

      included do
        class_attribute :verbose_errors_enabled, default: false

        attr_reader :_logger, :_verbose_errors_enabled
      end

      class_methods do
        def enable_verbose_errors!
          self.verbose_errors_enabled = true
        end
      end

      def initialize(options)
        @_logger = options.delete("logger")
        @_verbose_errors_enabled = options.delete("verbose_errors") || options.delete("verbose_errors_enabled")

        super
      end

      protected

      def verbose_errors?
        # Check multiple sources for verbose setting (in priority order)
        # 1. Instance config (highest priority)
        return true if _verbose_errors_enabled

        # 2. Class-level setting
        return true if self.class.verbose_errors_enabled

        # 3. ActiveAgent global configuration
        if defined?(ActiveAgent) && ActiveAgent.respond_to?(:configuration)
          return true if ActiveAgent.configuration.verbose_generation_errors?
        end

        # 4. Environment variable (lowest priority)
        ENV["ACTIVE_AGENT_VERBOSE_ERRORS"] == "true"
      end

      def log_error_details(error)
        logger = find_logger
        return unless logger

        logger.error "[ActiveAgent::Providers] Error: #{error.class.name}: #{error.message}"
        if logger.respond_to?(:debug) && error.respond_to?(:backtrace)
          logger.debug "Backtrace:\n  #{error.backtrace&.first(10)&.join("\n  ")}"
        end
      end

      def log_retry(error, attempt, max_retries)
        logger = find_logger
        return unless logger

        message = "[ActiveAgent::Providers] Retry attempt #{attempt}/#{max_retries} after #{error.class.name}"
        logger.info message
      end

      def find_logger
        # Try multiple logger sources (in priority order)
        # 1. Instance config
        return _logger if _logger

        # 2. ActiveAgent configuration logger
        if defined?(ActiveAgent) && ActiveAgent.respond_to?(:configuration)
          config_logger = ActiveAgent.configuration.generation_provider_logger
          return config_logger if config_logger
        end

        # 3. Rails logger
        return Rails.logger if defined?(Rails) && Rails.logger

        # 4. ActiveAgent::Base logger
        return ActiveAgent::Base.logger if defined?(ActiveAgent::Base) && ActiveAgent::Base.respond_to?(:logger)

        nil
      end
    end
  end
end
