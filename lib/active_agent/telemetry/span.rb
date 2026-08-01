# frozen_string_literal: true

module ActiveAgent
  module Telemetry
    # The framework's span, now provided by the activeagents-telemetry gem.
    # This subclass translates the framework's historical constructor
    # (span_type: keyword, attributes as a keyword splat) onto the shared
    # class; everything else — set_attribute, set_tokens, set_status,
    # record_error, add_span, measure, finish — is inherited.
    #
    # One deliberate change rides along from the shared core: record_error
    # truncates the message and no longer puts a backtrace on the wire.
    #
    # @see ActiveAgents::Telemetry::Span
    class Span < ActiveAgents::Telemetry::Span
      def initialize(name, trace_id:, parent_span_id: nil, span_type: :root, **attributes)
        super(
          name,
          type: span_type,
          trace_id: trace_id,
          parent_span_id: parent_span_id,
          attributes: attributes
        )
      end

      # Creates a child span, keeping the framework's keyword shape.
      def add_span(name, span_type: :root, **attributes)
        child = Span.new(
          name,
          trace_id: trace_id,
          parent_span_id: span_id,
          span_type: span_type,
          **attributes
        )
        children << child
        child
      end
    end
  end
end
