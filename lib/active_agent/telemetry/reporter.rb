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
        @send_threads = []
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

      # Flushes all buffered traces immediately and waits for the send to
      # complete, so callers (tests, rails runner, job shutdown) can rely on
      # the traces having been delivered/stored when this returns.
      #
      # @return [void]
      def flush
        thread = @mutex.synchronize { flush_buffer }
        thread&.join(configuration.timeout)
      end

      # Shuts down the reporter, flushing remaining traces and waiting for
      # any in-flight sends — without this, traces flushed near process exit
      # were silently dropped.
      #
      # @return [void]
      def shutdown
        @shutdown = true
        @running = false
        flush
        @thread&.join(5) # Wait up to 5 seconds for thread to finish
        @mutex.synchronize { @send_threads.dup }.each { |t| t.join(configuration.timeout) }
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

      # Flushes the buffer by sending traces to the endpoint on a background
      # thread. Must be called within @mutex synchronization.
      #
      # @return [Thread, nil] the send thread, so callers can join it
      def flush_buffer
        return if @buffer.empty?

        traces = @buffer.dup
        @buffer.clear

        @send_threads.select!(&:alive?)
        thread = Thread.new { send_traces(traces) }
        @send_threads << thread
        thread
      end

      # Sends traces to the configured endpoint.
      #
      # @param traces [Array<Hash>] Traces to send
      def send_traces(traces)
        # Use direct database storage for local mode
        if configuration.local_storage?
          store_traces_locally(traces)
          return
        end

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

      # Stores traces directly in the local database.
      #
      # @param traces [Array<Hash>] Traces to store
      def store_traces_locally(traces)
        sdk_info = {
          "name" => "activeagent",
          "version" => ActiveAgent::VERSION,
          "language" => "ruby",
          "runtime_version" => RUBY_VERSION
        }

        model = local_trace_model
        unless model
          log_error("local_storage is enabled but no trace model is available — " \
            "run `rails generate active_agent:dashboard:install` first")
          return
        end

        traces.each do |trace|
          # Tracer payloads are symbol-keyed; create_from_payload reads
          # string keys (as it does for JSON ingested over HTTP).
          trace = trace.deep_stringify_keys if trace.respond_to?(:deep_stringify_keys)

          # Skip if trace already exists (idempotency)
          next if model.exists?(trace_id: trace["trace_id"])

          model.create_from_payload(trace, sdk_info)
        rescue StandardError => e
          log_error("Failed to store trace locally: #{e.class} - #{e.message}")
        end
      rescue StandardError => e
        log_error("Error storing traces locally: #{e.class} - #{e.message}")
      end

      # Resolves the configured trace model (honors
      # ActiveAgent::Dashboard.trace_model_class overrides).
      def local_trace_model
        if defined?(ActiveAgent::Dashboard) && ActiveAgent::Dashboard.respond_to?(:trace_model)
          ActiveAgent::Dashboard.trace_model
        elsif defined?(ActiveAgent::TelemetryTrace)
          ActiveAgent::TelemetryTrace
        end
      rescue NameError
        nil
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
