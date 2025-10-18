# frozen_string_literal: true

require "active_support/log_subscriber"

module ActiveAgent
  # Log subscriber for ActiveAgent provider operations.
  #
  # This subscriber listens to ActiveSupport::Notifications events published
  # during provider operations and logs them in a consistent, configurable format.
  #
  # Events are automatically instrumented in the providers and can be customized
  # or disabled through log level configuration.
  #
  # @example Custom log formatting
  #   class MyLogSubscriber < ActiveAgent::LogSubscriber
  #     def prompt_start(event)
  #       info "🚀 Starting prompt: #{event.payload[:provider]}"
  #     end
  #   end
  #
  #   ActiveAgent::LogSubscriber.detach_from :active_agent_provider
  #   MyLogSubscriber.attach_to :active_agent_provider
  class LogSubscriber < ActiveSupport::LogSubscriber
    # Logs the start of a prompt request
    #
    # @param event [ActiveSupport::Notifications::Event]
    def prompt_start(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      debug color("[#{provider_module}] Starting prompt request", CYAN)
    end

    # Logs the start of an embedding request
    #
    # @param event [ActiveSupport::Notifications::Event]
    def embed_start(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      debug color("[#{provider_module}] Starting embed request", CYAN)
    end

    # Logs request preparation details
    #
    # @param event [ActiveSupport::Notifications::Event]
    def request_prepared(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      message_count = event.payload[:message_count]
      debug color("[#{provider_module}] Prepared request with #{message_count} message(s)", BLUE)
    end

    # Logs API call execution
    #
    # @param event [ActiveSupport::Notifications::Event]
    def api_call(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      streaming = event.payload[:streaming]
      duration = event.duration.round(1)

      message = "[#{provider_module}] API call completed in #{duration}ms (streaming: #{streaming})"
      debug color(message, MAGENTA, bold: true)
    end

    # Logs embed API call execution
    #
    # @param event [ActiveSupport::Notifications::Event]
    def embed_call(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      duration = event.duration.round(1)

      debug color("[#{provider_module}] Embed API call completed in #{duration}ms", MAGENTA, bold: true)
    end

    # Logs stream opening
    #
    # @param event [ActiveSupport::Notifications::Event]
    def stream_open(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      debug color("[#{provider_module}] Opening stream", GREEN)
    end

    # Logs stream closing
    #
    # @param event [ActiveSupport::Notifications::Event]
    def stream_close(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      debug color("[#{provider_module}] Closing stream", GREEN)
    end

    # Logs message extraction from API response
    #
    # @param event [ActiveSupport::Notifications::Event]
    def messages_extracted(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      message_count = event.payload[:message_count]
      debug color("[#{provider_module}] Extracted #{message_count} message(s) from API response", BLUE)
    end

    # Logs tool/function call processing
    #
    # @param event [ActiveSupport::Notifications::Event]
    def tool_calls_processing(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      tool_count = event.payload[:tool_count]
      debug color("[#{provider_module}] Processing #{tool_count} tool call(s)", YELLOW)
    end

    # Logs multi-turn conversation continuation
    #
    # @param event [ActiveSupport::Notifications::Event]
    def multi_turn_continue(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      debug color("[#{provider_module}] Continuing multi-turn conversation after tool execution", YELLOW)
    end

    # Logs prompt completion
    #
    # @param event [ActiveSupport::Notifications::Event]
    def prompt_complete(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      message_count = event.payload[:message_count]
      duration = event.duration.round(1)

      message = "[#{provider_module}] Prompt completed with #{message_count} message(s) in stack (total: #{duration}ms)"
      debug color(message, GREEN, bold: true)
    end

    # Logs retry attempts
    #
    # @param event [ActiveSupport::Notifications::Event]
    def retry_attempt(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      attempt = event.payload[:attempt]
      max_retries = event.payload[:max_retries]
      exception = event.payload[:exception]
      backoff_time = event.payload[:backoff_time]

      debug color("[#{provider_module}:Retries] Attempt #{attempt}/#{max_retries} failed with #{exception}, retrying in #{backoff_time}s", RED)
    end

    # Logs when max retries are exceeded
    #
    # @param event [ActiveSupport::Notifications::Event]
    def retry_exhausted(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      max_retries = event.payload[:max_retries]
      exception = event.payload[:exception]

      debug color("[#{provider_module}:Retries] Max retries (#{max_retries}) exceeded for #{exception}", RED, bold: true)
    end

    # Logs tool execution
    #
    # @param event [ActiveSupport::Notifications::Event]
    def tool_execution(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      tool_name = event.payload[:tool_name]

      debug color("[#{provider_module}] Executing tool: #{tool_name}", YELLOW)
    end

    # Logs tool choice removal
    #
    # @param event [ActiveSupport::Notifications::Event]
    def tool_choice_removed(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      debug color("[#{provider_module}] Removing tool_choice constraint after tool execution", YELLOW)
    end

    # Logs API request
    #
    # @param event [ActiveSupport::Notifications::Event]
    def api_request(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      model = event.payload[:model]
      streaming = event.payload[:streaming]

      if streaming.nil?
        debug color("[#{provider_module}] Executing request to #{model}", BLUE)
      else
        mode = streaming ? "streaming" : "non-streaming"
        debug color("[#{provider_module}] Executing #{mode} request to #{model}", BLUE)
      end
    end

    # Logs stream chunk processing
    #
    # @param event [ActiveSupport::Notifications::Event]
    def stream_chunk_processing(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      chunk_type = event.payload[:chunk_type]

      if chunk_type
        debug color("[#{provider_module}] Processing stream chunk: #{chunk_type}", BLUE)
      else
        debug color("[#{provider_module}] Processing stream chunk", BLUE)
      end
    end

    # Logs stream finished
    #
    # @param event [ActiveSupport::Notifications::Event]
    def stream_finished(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      finish_reason = event.payload[:finish_reason]

      debug color("[#{provider_module}] Stream finished with reason: #{finish_reason}", GREEN)
    end

    # Logs API routing decisions
    #
    # @param event [ActiveSupport::Notifications::Event]
    def api_routing(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      api_type = event.payload[:api_type]
      api_version = event.payload[:api_version]
      has_audio = event.payload[:has_audio]

      if has_audio
        debug color("[#{provider_module}] Routing to #{api_type.to_s.capitalize} API (api_version: #{api_version}, audio: #{has_audio})", CYAN)
      else
        debug color("[#{provider_module}] Routing to #{api_type.to_s.capitalize} API (api_version: #{api_version})", CYAN)
      end
    end

    # Logs embeddings requests
    #
    # @param event [ActiveSupport::Notifications::Event]
    def embeddings_request(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      debug color("[#{provider_module}] Executing embeddings request", BLUE)
    end

    # Logs connection errors
    #
    # @param event [ActiveSupport::Notifications::Event]
    def connection_error(event)
      return unless logger.debug?

      provider_module = event.payload[:provider_module]
      uri_base = event.payload[:uri_base]
      exception = event.payload[:exception]
      message = event.payload[:message]

      debug color(
        "[#{provider_module}] Unable to connect to #{uri_base}. " \
        "Please ensure the service is running. " \
        "Error: #{exception} - #{message}",
        RED
      )
    end

    private

    # Returns the configured logger
    #
    # @return [Logger]
    def logger
      ActiveAgent.logger
    end

    # Adds color to log messages
    #
    # @param text [String] The text to colorize
    # @param color [Integer] ANSI color code constant
    # @param bold [Boolean] Whether to make text bold
    # @return [String] Colorized text
    def color(text, color_code, bold: false)
      return text unless colorize_logging

      codes = [ color_code ]
      codes << BOLD if bold
      "\e[#{codes.join(';')}m#{text}\e[0m"
    end

    # Whether to colorize log output
    #
    # @return [Boolean]
    def colorize_logging
      ActiveAgent.configuration.colorize_logging
    end
  end
end
