# frozen_string_literal: true

module ActionAgent
  # Serializes TelemetryTrace records (gem span payloads) into the view-model
  # consumed by the dashboard's TracesView: relative span offsets for the
  # waterfall timeline, nesting depth, and token totals.
  class TelemetryTraceSerializer
    # Span types understood by the dashboard timeline (superset of the gem's
    # ActiveAgent::Telemetry::Span::TYPES).
    KNOWN_SPAN_TYPES = %w[root prompt generate llm tool thinking embedding response error].freeze

    def self.summary(trace)
      new(trace).summary
    end

    def self.detail(trace)
      new(trace).detail
    end

    def initialize(trace)
      @trace = trace
    end

    def summary
      {
        id: @trace.id,
        trace_id: @trace.trace_id,
        short_id: @trace.trace_id&.first(8),
        agent: @trace.agent_class,
        action: @trace.agent_action,
        display_name: @trace.display_name,
        service_name: @trace.service_name,
        environment: @trace.environment,
        provider: @trace.provider,
        model: @trace.model,
        status: @trace.status,
        error: @trace.error_message,
        duration_ms: @trace.total_duration_ms&.to_f&.round(2),
        timestamp: @trace.timestamp&.iso8601(3),
        timestamp_ms: @trace.timestamp&.to_f&.*(1000)&.round,
        tokens: {
          input: @trace.total_input_tokens || 0,
          output: @trace.total_output_tokens || 0,
          thinking: @trace.total_thinking_tokens || 0,
          total: @trace.total_tokens
        },
        estimated_cost: ModelPricing.estimate(
          model: @trace.model,
          input_tokens: @trace.total_input_tokens,
          output_tokens: @trace.total_output_tokens
        ),
        spans: serialized_spans
      }
    end

    def detail
      summary.merge(
        resource_attributes: @trace.resource_attributes,
        sdk_info: @trace.sdk_info
      )
    end

    private

    # Maps raw gem spans (start_time/end_time ISO strings, parent_span_id
    # links) to waterfall rows with millisecond offsets relative to the root
    # span and a nesting depth.
    def serialized_spans
      spans = Array(@trace.spans)
      return [] if spans.empty?

      by_id = spans.index_by { |s| s["span_id"] }
      root = spans.find { |s| s["parent_span_id"].nil? } || spans.first
      root_start = parse_time(root["start_time"])

      spans.map do |span|
        start = parse_time(span["start_time"])
        offset = (root_start && start) ? ((start - root_start) * 1000).round(2) : 0

        {
          span_id: span["span_id"],
          name: span["name"],
          type: normalized_type(span),
          start: [ offset, 0 ].max,
          duration: span["duration_ms"]&.to_f&.round(2) || 0,
          nested: depth_of(span, by_id),
          status: span["status"],
          error: span["status"] == "ERROR",
          tokens: span["tokens"],
          attributes: span["attributes"]
        }
      end
    end

    def normalized_type(span)
      type = span["type"].to_s
      KNOWN_SPAN_TYPES.include?(type) ? type : "root"
    end

    def depth_of(span, by_id)
      depth = 0
      current = span
      while (parent_id = current["parent_span_id"])
        parent = by_id[parent_id]
        break unless parent

        depth += 1
        current = parent
        break if depth > 10
      end
      depth
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
