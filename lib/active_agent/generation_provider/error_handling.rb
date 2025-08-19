# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module ErrorHandling
      extend ActiveSupport::Concern
      include ActiveSupport::Rescuable

      included do
        class_attribute :retry_on_errors, default: []
        class_attribute :max_retries, default: 3
        class_attribute :verbose_errors_enabled, default: false

        # Use rescue_from for provider-specific error handling
        rescue_from StandardError, with: :handle_generation_error
      end

      def with_error_handling
        retries = 0
        begin
          yield
        rescue => e
          if should_retry?(e) && retries < max_retries
            retries += 1
            log_retry(e, retries) if verbose_errors?
            sleep(retry_delay(retries))
            retry
          else
            # Use rescue_with_handler from Rescuable
            rescue_with_handler(e) || raise
          end
        end
      end

      protected

      def should_retry?(error)
        return false if retry_on_errors.empty?
        retry_on_errors.any? { |klass| error.is_a?(klass) }
      end

      def retry_delay(attempt)
        # Exponential backoff: 1s, 2s, 4s...
        2 ** (attempt - 1)
      end

      def handle_generation_error(error)
        error_message = format_error_message(error)
        # Create new error with original backtrace preserved
        new_error = ActiveAgent::GenerationProvider::Base::GenerationProviderError.new(error_message)
        new_error.set_backtrace(error.backtrace) if error.respond_to?(:backtrace)

        # Log detailed error if verbose mode is enabled
        log_error_details(error) if verbose_errors?

        # Instrument the error for LogSubscriber
        instrument_error(error, new_error)

        raise new_error
      end

      def format_error_message(error)
        message = if error.respond_to?(:response)
          error.response[:body]
        elsif error.respond_to?(:message)
          error.message
        elsif error.respond_to?(:to_s)
          error.to_s
        else
          "An unknown error occurred: #{error.class.name}"
        end

        # Include error class in verbose mode
        if verbose_errors?
          "[#{error.class.name}] #{message}"
        else
          message
        end
      end

      def verbose_errors?
        # Check multiple sources for verbose setting (in priority order)
        # 1. Instance config (highest priority)
        return true if @config&.dig("verbose_errors")

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

        logger.error "[ActiveAgent::GenerationProvider] Error: #{error.class.name}: #{error.message}"
        if logger.respond_to?(:debug) && error.respond_to?(:backtrace)
          logger.debug "Backtrace:\n  #{error.backtrace&.first(10)&.join("\n  ")}"
        end
      end

      def log_retry(error, attempt)
        logger = find_logger
        return unless logger

        message = "[ActiveAgent::GenerationProvider] Retry attempt #{attempt}/#{max_retries} after #{error.class.name}"
        logger.info message
      end

      def find_logger
        # Try multiple logger sources (in priority order)
        # 1. Instance config
        return @config["logger"] if @config&.dig("logger")

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

      def instrument_error(original_error, wrapped_error)
        if defined?(ActiveSupport::Notifications)
          ActiveSupport::Notifications.instrument("error.active_agent", {
            error_class: original_error.class.name,
            error_message: original_error.message,
            wrapped_error: wrapped_error,
            provider: self.class.name
          })
        end
      end

      module ClassMethods
        def retry_on(*errors, max_attempts: 3, **options)
          self.retry_on_errors = errors
          self.max_retries = max_attempts

          # Also register with rescue_from for more complex handling
          errors.each do |error_class|
            rescue_from error_class do |error|
              # This will be caught by with_error_handling for retry logic
              raise error
            end
          end
        end

        def enable_verbose_errors!
          self.verbose_errors_enabled = true
        end
      end
    end
  end
end
