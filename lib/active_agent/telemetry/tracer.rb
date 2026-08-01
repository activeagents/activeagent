# frozen_string_literal: true

module ActiveAgent
  module Telemetry
    # Manages trace creation and lifecycle.
    #
    # The Tracer creates traces, manages the current trace context,
    # and coordinates with the Reporter for async transmission.
    #
    # @example Basic usage
    #   tracer = Tracer.new(configuration)
    #   tracer.trace("MyAgent.greet") do |span|
    #     span.set_attribute("user_id", 123)
    #     span.add_span("llm.generate", span_type: :llm)
    #   end
    #
    class Tracer
      # @return [Configuration] Telemetry configuration
      attr_reader :configuration

      # @return [Reporter] The reporter for sending traces
      attr_reader :reporter

      # Thread-local storage for current trace context
      CURRENT_SPAN_KEY = :active_agent_telemetry_current_span

      def initialize(configuration)
        @configuration = configuration
        @reporter = Reporter.new(configuration)
        @mutex = Mutex.new
      end

      # Creates and executes a new trace.
      #
      # @param name [String] Trace name (typically "AgentClass.action")
      # @param attributes [Hash] Root span attributes
      # @yield [span] Yields the root span for adding child spans
      # @return [Object] Result of the block
      #
      # @example
      #   tracer.trace("WeatherAgent.forecast") do |span|
      #     span.set_attribute("location", "Seattle")
      #     result = do_llm_call
      #     span.set_tokens(input: 100, output: 50)
      #     result
      #   end
      def trace(name, **attributes, &block)
        return yield(Telemetry::NullSpan.new) unless should_trace?

        # Callers may supply the trace id (instrumentation passes the
        # generation's prompt_options[:trace_id]) so external records can
        # correlate with this trace; otherwise generate one.
        trace_id = attributes.delete(:trace_id) || generate_trace_id
        root_span = Span.new(
          name,
          trace_id: trace_id,
          span_type: :root,
          **default_attributes.merge(attributes)
        )

        with_span(root_span) do
          result = yield(root_span)
          root_span.finish
          report_trace(root_span)
          result
        end
      rescue StandardError => e
        root_span&.record_error(e)
        root_span&.finish
        report_trace(root_span) if root_span
        raise
      end

      # Creates a standalone span (not within a trace block).
      #
      # @param name [String] Span name
      # @param attributes [Hash] Span attributes
      # @return [Span] The created span
      def span(name, **attributes)
        return Telemetry::NullSpan.new unless should_trace?

        current = current_span
        if current
          current.add_span(name, **attributes)
        else
          Span.new(name, trace_id: generate_trace_id, **default_attributes.merge(attributes))
        end
      end

      # Returns the current span from thread-local storage.
      #
      # @return [Span, nil] Current span or nil
      def current_span
        Thread.current[CURRENT_SPAN_KEY]
      end

      # Flushes buffered traces immediately.
      #
      # @return [void]
      def flush
        reporter.flush
      end

      # Shuts down the tracer and reporter.
      #
      # @return [void]
      def shutdown
        reporter.shutdown
      end

      private

      # Executes block with span as current context.
      #
      # @param span [Span] Span to set as current
      # @yield Block to execute
      # @return [Object] Result of block
      def with_span(span)
        previous = Thread.current[CURRENT_SPAN_KEY]
        Thread.current[CURRENT_SPAN_KEY] = span
        yield
      ensure
        Thread.current[CURRENT_SPAN_KEY] = previous
      end

      # Reports a completed trace to the reporter.
      #
      # @param span [Span] Root span of the trace
      def report_trace(span)
        reporter.report(build_trace_payload(span))
      end

      # Builds the trace payload for transmission.
      #
      # @param root_span [Span] Root span
      # @return [Hash] Trace payload
      def build_trace_payload(root_span)
        {
          trace_id: root_span.trace_id,
          service_name: configuration.resolved_service_name,
          environment: configuration.environment,
          timestamp: Time.current.iso8601(6),
          resource_attributes: configuration.resource_attributes,
          spans: redact_spans(flatten_spans(root_span))
        }
      end

      # Redacts span (and span-event) attributes whose keys match any
      # configured redact_attributes entry, before the payload leaves the
      # process. Matching is case-insensitive substring — deliberately
      # over-broad: better to redact a harmless "max_tokens" than to ship
      # an "api_key".
      #
      # @param spans [Array<Hash>] flattened span data
      # @return [Array<Hash>]
      def redact_spans(spans)
        patterns = Array(configuration.redact_attributes).map(&:to_s).reject(&:empty?)
        return spans if patterns.empty?

        matcher = Regexp.union(patterns.map { |pattern| Regexp.new(Regexp.escape(pattern), Regexp::IGNORECASE) })
        spans.map { |span| redact_span(span, matcher) }
      end

      # Flattens span hierarchy into array.
      #
      # @param span [Span] Root span
      # @return [Array<Hash>] Flattened span data
      def flatten_spans(span)
        result = [ span.to_h.except(:children) ]
        span.children.each do |child|
          result.concat(flatten_spans(child))
        end
        result
      end

      # @param span [Hash]
      # @param matcher [Regexp]
      # @return [Hash] span with matching attribute values replaced
      def redact_span(span, matcher)
        span = span.dup
        span[:attributes] = redact_hash(span[:attributes], matcher) if span[:attributes].is_a?(Hash)
        if span[:events].is_a?(Array)
          span[:events] = span[:events].map do |event|
            next event unless event.is_a?(Hash) && event[:attributes].is_a?(Hash)

            event.merge(attributes: redact_hash(event[:attributes], matcher))
          end
        end
        span
      end

      REDACTED = "[REDACTED]"

      def redact_hash(attributes, matcher)
        attributes.to_h do |key, value|
          [ key, key.to_s.match?(matcher) ? REDACTED : value ]
        end
      end

      # Returns whether this trace should be sampled.
      #
      # @return [Boolean]
      def should_trace?
        configuration.enabled? && configuration.configured? && configuration.should_sample?
      end

      # Generates a unique trace ID.
      #
      # @return [String] 32-character hex trace ID
      def generate_trace_id
        SecureRandom.hex(16)
      end

      # Returns default attributes for all spans.
      #
      # @return [Hash] Default attributes
      def default_attributes
        {
          "service.name" => configuration.resolved_service_name,
          "service.environment" => configuration.environment,
          "telemetry.sdk.name" => "activeagent",
          "telemetry.sdk.version" => ActiveAgent::VERSION
        }
      end
    end
  end
end
