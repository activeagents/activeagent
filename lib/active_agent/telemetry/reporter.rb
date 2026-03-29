# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module ActiveAgent
  module Telemetry
    # Asynchronously reports traces to the telemetry endpoint.
    #
    # Buffers traces and sends them in batches to reduce network overhead.
    # Uses a background thread for non-blocking transmission.
    #
    # @example
    #   reporter = Reporter.new(configuration)
    #   reporter.report(trace_payload)
    #   reporter.flush  # Send immediately
    #   reporter.shutdown  # Clean shutdown
    #
    class Reporter
      # @return [Configuration] Telemetry configuration
      attr_reader :configuration

      def initialize(configuration)
        @configuration = configuration
        @buffer = []
        @mutex = Mutex.new
        @running = false
        @thread = nil
        @shutdown = false

        start_flush_thread if configuration.enabled?
      end

      # Adds a trace to the buffer for transmission.
      #
      # @param trace [Hash] Trace payload
      # @return [void]
      def report(trace)
        return unless configuration.enabled?

        @mutex.synchronize do
          @buffer << trace

          # Flush immediately if buffer is full
          if @buffer.size >= configuration.batch_size
            flush_buffer
          end
        end
      end

      # Flushes all buffered traces immediately.
      #
      # @return [void]
      def flush
        @mutex.synchronize do
          flush_buffer
        end
      end

      # Shuts down the reporter, flushing remaining traces.
      #
      # @return [void]
      def shutdown
        @shutdown = true
        flush
        @thread&.join(5) # Wait up to 5 seconds for thread to finish
      end

      private

      # Starts the background flush thread.
      def start_flush_thread
        @running = true
        @thread = Thread.new do
          Thread.current.name = "activeagent-telemetry-reporter"

          while @running && !@shutdown
            sleep(configuration.flush_interval)

            @mutex.synchronize do
              flush_buffer if @buffer.any?
            end
          end
        end
      end

      # Flushes the buffer by sending traces to the endpoint.
      #
      # Must be called within @mutex synchronization.
      def flush_buffer
        return if @buffer.empty?

        traces = @buffer.dup
        @buffer.clear

        Thread.new { send_traces(traces) }
      end

      # Sends traces to the configured endpoint.
      #
      # @param traces [Array<Hash>] Traces to send
      def send_traces(traces)
        uri = URI.parse(configuration.endpoint)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = configuration.timeout
        http.read_timeout = configuration.timeout

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{configuration.api_key}"
        request["User-Agent"] = "ActiveAgent/#{ActiveAgent::VERSION} Ruby/#{RUBY_VERSION}"
        request["X-Service-Name"] = configuration.resolved_service_name
        request["X-Environment"] = configuration.environment

        payload = {
          traces: traces,
          sdk: {
            name: "activeagent",
            version: ActiveAgent::VERSION,
            language: "ruby",
            runtime_version: RUBY_VERSION
          }
        }

        request.body = JSON.generate(payload)

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          log_error("Failed to send traces: #{response.code} #{response.message}")
        end
      rescue StandardError => e
        log_error("Error sending traces: #{e.class} - #{e.message}")
      end

      # Logs an error message.
      #
      # @param message [String] Error message
      def log_error(message)
        configuration.resolved_logger.error("[ActiveAgent::Telemetry] #{message}")
      end
    end
  end
end
