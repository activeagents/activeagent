# frozen_string_literal: true

module ActiveAgent
  module Telemetry
    # Manages trace creation and lifecycle on the activeagents-telemetry
    # core: builds an ActiveAgents::Telemetry::Trace per unit of work, tracks
    # the current span in thread-local storage, and hands finished traces to
    # the Reporter.
    #
    # @example
    #   tracer = Tracer.new(configuration)
    #   tracer.trace("MyAgent.greet") do |span|
    #     span.set_attribute("user_id", 123)
    #     span.add_span("llm.generate", span_type: :llm)
    #   end
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
      end

      # Creates and executes a new trace.
      #
      # Callers may supply the trace id (instrumentation passes the
      # generation's prompt_options[:trace_id]) so external records — e.g.
      # solid_agent's persisted generations — can correlate with this trace;
      # otherwise one is generated.
      #
      # @param name [String] Trace name (typically "AgentClass.action")
      # @param attributes [Hash] Root span attributes; :trace_id and
      #   :span_type are extracted rather than recorded
      # @yield [span] Yields the root span for adding child spans
      # @return [Object] Result of the block
      def trace(name, **attributes)
        return yield(Telemetry::NullSpan.new) unless should_trace?

        trace_id = attributes.delete(:trace_id) || SecureRandom.hex(16)
        span_type = attributes.delete(:span_type) || :root

        trace = build_trace(trace_id)
        root_span = Span.new(
          name,
          trace_id: trace_id,
          span_type: span_type,
          **default_attributes.merge(attributes)
        )
        trace.add_span(root_span)

        with_span(root_span) do
          result = yield(root_span)
          root_span.finish
          reporter.report(redact_trace!(trace))
          result
        end
      rescue StandardError => e
        if root_span && !root_span.finished?
          root_span.record_error(e)
          root_span.finish
          reporter.report(redact_trace!(trace))
        end
        raise
      end

      # Creates a standalone span (not within a trace block).
      #
      # @param name [String] Span name
      # @param attributes [Hash] Span attributes
      # @return [Span] The created span
      def span(name, **attributes)
        return Telemetry::NullSpan.new unless should_trace?

        span_type = attributes.delete(:span_type) || :root
        current = current_span
        if current
          current.add_span(name, span_type: span_type, **attributes)
        else
          Span.new(name, trace_id: SecureRandom.hex(16), span_type: span_type, **default_attributes.merge(attributes))
        end
      end

      # Returns the current span from thread-local storage.
      #
      # @return [Span, nil] Current span or nil
      def current_span
        Thread.current[CURRENT_SPAN_KEY]
      end

      # Flushes buffered traces and waits for delivery to complete, so
      # callers (tests, rails runner, job shutdown) can rely on the traces
      # having been delivered/stored when this returns.
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

      def build_trace(trace_id)
        ActiveAgents::Telemetry::Trace.new(
          trace_id: trace_id,
          service_name: configuration.resolved_service_name,
          environment: configuration.resolved_environment,
          resource_attributes: configuration.resource_attributes
        )
      end

      # Executes block with span as current context.
      def with_span(span)
        previous = Thread.current[CURRENT_SPAN_KEY]
        Thread.current[CURRENT_SPAN_KEY] = span
        yield
      ensure
        Thread.current[CURRENT_SPAN_KEY] = previous
      end

      # Redacts span (and span-event) attributes whose keys match any
      # configured redact_attributes entry, before the trace is handed to
      # the reporter. Matching is case-insensitive substring — deliberately
      # over-broad: better to redact a harmless "max_tokens" than to ship
      # an "api_key". (Ported from the pre-shared-core payload builder,
      # which no longer exists — the gem's reporter ships the trace as-is.)
      REDACTED = "[REDACTED]"

      def redact_trace!(trace)
        patterns = Array(configuration.redact_attributes).map(&:to_s).reject(&:empty?)
        return trace if patterns.empty?

        matcher = Regexp.union(patterns.map { |pattern| Regexp.new(Regexp.escape(pattern), Regexp::IGNORECASE) })
        Array(trace.spans).each { |span| redact_span!(span, matcher) }
        trace
      end

      def redact_span!(span, matcher)
        redact_hash!(span.attributes, matcher) if span.attributes.is_a?(Hash)
        Array(span.events).each do |event|
          attributes = event.is_a?(Hash) ? (event["attributes"] || event[:attributes]) : nil
          redact_hash!(attributes, matcher) if attributes.is_a?(Hash)
        end
        Array(span.children).each { |child| redact_span!(child, matcher) }
      end

      def redact_hash!(attributes, matcher)
        attributes.each_key do |key|
          attributes[key] = REDACTED if key.to_s.match?(matcher)
        end
      end

      # Returns whether this trace should be collected at all.
      def should_trace?
        configuration.enabled? && configuration.configured? && configuration.should_sample?
      end

      # Returns default attributes for all spans.
      def default_attributes
        {
          "service.name" => configuration.resolved_service_name,
          "service.environment" => configuration.resolved_environment,
          "telemetry.sdk.name" => "activeagent",
          "telemetry.sdk.version" => ActiveAgent::VERSION
        }
      end
    end
  end
end
