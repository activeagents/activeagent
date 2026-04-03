# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"

module ActiveAgent
  # Telemetry module for collecting and reporting agent traces.
  #
  # Provides optional observability by capturing agent generation traces,
  # tool calls, token usage, and errors. Reports to a configured endpoint
  # (self-hosted or ActiveAgents.ai hosted service).
  #
  # = Features
  #
  # * **Trace Collection**: Captures full generation lifecycle with spans
  # * **Token Tracking**: Records input/output/thinking tokens per generation
  # * **Tool Call Tracing**: Captures tool invocations with arguments and results
  # * **Error Tracking**: Records errors with backtraces
  # * **Async Reporting**: Non-blocking HTTP reporting with background thread
  #
  # = Configuration
  #
  # Configure in your Rails initializer or activeagent.yml:
  #
  # @example Basic configuration
  #   ActiveAgent::Telemetry.configure do |config|
  #     config.enabled = true
  #     config.endpoint = "https://api.activeagents.ai/v1/traces"
  #     config.api_key = Rails.application.credentials.dig(:activeagents, :api_key)
  #   end
  #
  # @example YAML configuration (config/activeagent.yml)
  #   telemetry:
  #     enabled: true
  #     endpoint: https://api.activeagents.ai/v1/traces
  #     api_key: <%= Rails.application.credentials.dig(:activeagents, :api_key) %>
  #     sample_rate: 1.0
  #     batch_size: 100
  #     flush_interval: 5
  #
  # @example Self-hosted endpoint
  #   ActiveAgent::Telemetry.configure do |config|
  #     config.endpoint = "https://observability.mycompany.com/v1/traces"
  #     config.api_key = ENV["TELEMETRY_API_KEY"]
  #   end
  #
  # @see ActiveAgent::Telemetry::Configuration
  # @see ActiveAgent::Telemetry::Tracer
  module Telemetry
    extend ActiveSupport::Autoload

    autoload :Configuration
    autoload :Tracer
    autoload :Span
    autoload :Reporter
    autoload :Instrumentation

    class << self
      # Returns the telemetry configuration instance.
      #
      # @return [Configuration] The configuration instance
      def configuration
        @configuration ||= Configuration.new
      end

      # Configures telemetry with a block.
      #
      # @yield [config] Yields the configuration instance
      # @yieldparam config [Configuration] The configuration to modify
      # @return [Configuration] The modified configuration
      #
      # @example
      #   ActiveAgent::Telemetry.configure do |config|
      #     config.enabled = true
      #     config.endpoint = "https://api.activeagents.ai/v1/traces"
      #     config.api_key = "your-api-key"
      #   end
      def configure
        yield configuration if block_given?
        configuration
      end

      # Resets the configuration to defaults.
      #
      # @return [Configuration] New default configuration
      def reset_configuration!
        @configuration = Configuration.new
      end

      # Returns whether telemetry is enabled and configured.
      #
      # @return [Boolean] True if telemetry should collect and report
      def enabled?
        configuration.enabled? && configuration.configured?
      end

      # Returns the global tracer instance.
      #
      # @return [Tracer] The tracer instance
      def tracer
        @tracer ||= Tracer.new(configuration)
      end

      # Starts a new trace for an agent generation.
      #
      # @param name [String] Name of the trace (typically agent.action)
      # @param attributes [Hash] Additional trace attributes
      # @yield [trace] Yields the trace for adding spans
      # @return [Span] The root span of the trace
      #
      # @example
      #   ActiveAgent::Telemetry.trace("WeatherAgent.forecast") do |trace|
      #     trace.add_span("llm.generate", provider: "anthropic")
      #     trace.set_tokens(input: 100, output: 50)
      #   end
      def trace(name, **attributes, &block)
        return yield(NullSpan.new) unless enabled?

        tracer.trace(name, **attributes, &block)
      end

      # Records a standalone span (outside of a trace context).
      #
      # @param name [String] Span name
      # @param attributes [Hash] Span attributes
      # @return [Span] The created span
      def span(name, **attributes)
        return NullSpan.new unless enabled?

        tracer.span(name, **attributes)
      end

      # Flushes any buffered traces immediately.
      #
      # @return [void]
      def flush
        tracer.flush if enabled?
      end

      # Shuts down telemetry, flushing remaining traces.
      #
      # @return [void]
      def shutdown
        tracer.shutdown if @tracer
      end
    end

    # Null span implementation for when telemetry is disabled.
    #
    # Provides no-op methods that match Span interface to avoid
    # nil checks throughout the codebase.
    class NullSpan
      def add_span(name, **attributes); self; end
      def set_attribute(key, value); self; end
      def set_tokens(input: 0, output: 0, thinking: 0); self; end
      def set_status(status, message = nil); self; end
      def record_error(error); self; end
      def finish; self; end
    end
  end
end
