# frozen_string_literal: true

module ActiveAgent
  module Telemetry
    # Represents a single span in a trace.
    #
    # Spans capture discrete operations within a trace, such as LLM calls,
    # tool invocations, or prompt rendering. Each span has timing, attributes,
    # and can have child spans.
    #
    # @example Creating a span
    #   span = Span.new("llm.generate", trace_id: trace.trace_id)
    #   span.set_attribute("provider", "anthropic")
    #   span.set_attribute("model", "claude-3-5-sonnet")
    #   span.set_tokens(input: 100, output: 50)
    #   span.finish
    #
    class Span
      # Span types for categorization
      TYPES = {
        root: "root",           # Root span for entire generation
        prompt: "prompt",       # Prompt preparation/rendering
        llm: "llm",             # LLM API call
        tool: "tool",           # Tool invocation
        thinking: "thinking",   # Extended thinking (Anthropic)
        embedding: "embedding", # Embedding generation
        error: "error"          # Error handling
      }.freeze

      # Span status codes
      STATUS = {
        unset: "UNSET",
        ok: "OK",
        error: "ERROR"
      }.freeze

      # @return [String] Unique identifier for this span
      attr_reader :span_id

      # @return [String] Trace ID this span belongs to
      attr_reader :trace_id

      # @return [String, nil] Parent span ID
      attr_reader :parent_span_id

      # @return [String] Span name (e.g., "llm.generate", "tool.get_weather")
      attr_reader :name

      # @return [String] Span type from TYPES
      attr_reader :span_type

      # @return [Time] When the span started
      attr_reader :start_time

      # @return [Time, nil] When the span ended
      attr_reader :end_time

      # @return [Hash] Span attributes
      attr_reader :attributes

      # @return [Array<Span>] Child spans
      attr_reader :children

      # @return [String] Status code from STATUS
      attr_reader :status

      # @return [String, nil] Status message
      attr_reader :status_message

      # @return [Array<Hash>] Events recorded during the span
      attr_reader :events

      # Creates a new span.
      #
      # @param name [String] Span name
      # @param trace_id [String] Parent trace ID
      # @param parent_span_id [String, nil] Parent span ID
      # @param span_type [Symbol] Type of span
      # @param attributes [Hash] Initial attributes
      def initialize(name, trace_id:, parent_span_id: nil, span_type: :root, **attributes)
        @span_id = SecureRandom.hex(8)
        @trace_id = trace_id
        @parent_span_id = parent_span_id
        @name = name
        @span_type = TYPES[span_type] || span_type.to_s
        @start_time = Time.current
        @end_time = nil
        @attributes = attributes.transform_keys(&:to_s)
        @children = []
        @status = STATUS[:unset]
        @status_message = nil
        @events = []
        @tokens = { input: 0, output: 0, thinking: 0, total: 0 }
      end

      # Creates a child span.
      #
      # @param name [String] Child span name
      # @param span_type [Symbol] Type of span
      # @param attributes [Hash] Span attributes
      # @return [Span] The child span
      def add_span(name, span_type: :root, **attributes)
        child = Span.new(
          name,
          trace_id: trace_id,
          parent_span_id: span_id,
          span_type: span_type,
          **attributes
        )
        @children << child
        child
      end

      # Sets a single attribute.
      #
      # @param key [String, Symbol] Attribute key
      # @param value [Object] Attribute value
      # @return [self]
      def set_attribute(key, value)
        @attributes[key.to_s] = value
        self
      end

      # Sets multiple attributes at once.
      #
      # @param attrs [Hash] Attributes to set
      # @return [self]
      def set_attributes(attrs)
        attrs.each { |k, v| set_attribute(k, v) }
        self
      end

      # Sets token usage for LLM spans.
      #
      # @param input [Integer] Input token count
      # @param output [Integer] Output token count
      # @param thinking [Integer] Thinking token count (Anthropic extended thinking)
      # @return [self]
      def set_tokens(input: 0, output: 0, thinking: 0)
        @tokens = {
          input: input,
          output: output,
          thinking: thinking,
          total: input + output + thinking
        }
        set_attribute("tokens.input", input)
        set_attribute("tokens.output", output)
        set_attribute("tokens.thinking", thinking) if thinking > 0
        set_attribute("tokens.total", @tokens[:total])
        self
      end

      # Returns token usage.
      #
      # @return [Hash] Token counts
      def tokens
        @tokens.dup
      end

      # Sets the span status.
      #
      # @param code [Symbol] Status code (:ok, :error, :unset)
      # @param message [String, nil] Optional status message
      # @return [self]
      def set_status(code, message = nil)
        @status = STATUS[code] || STATUS[:unset]
        @status_message = message
        self
      end

      # Records an error on the span.
      #
      # @param error [Exception] The error to record
      # @return [self]
      def record_error(error)
        set_status(:error, error.message)
        set_attribute("error.type", error.class.name)
        set_attribute("error.message", error.message)
        set_attribute("error.backtrace", error.backtrace&.first(10)&.join("\n"))

        add_event("exception", {
          "exception.type" => error.class.name,
          "exception.message" => error.message,
          "exception.stacktrace" => error.backtrace&.join("\n")
        })

        self
      end

      # Adds an event to the span.
      #
      # @param name [String] Event name
      # @param attributes [Hash] Event attributes
      # @return [self]
      def add_event(name, attributes = {})
        @events << {
          name: name,
          timestamp: Time.current.iso8601(6),
          attributes: attributes.transform_keys(&:to_s)
        }
        self
      end

      # Marks the span as finished.
      #
      # @return [self]
      def finish
        @end_time = Time.current
        set_status(:ok) if @status == STATUS[:unset]
        self
      end

      # Returns whether the span is finished.
      #
      # @return [Boolean]
      def finished?
        !@end_time.nil?
      end

      # Returns the duration in milliseconds.
      #
      # @return [Float, nil] Duration or nil if not finished
      def duration_ms
        return nil unless finished?

        ((@end_time - @start_time) * 1000).round(2)
      end

      # Serializes the span for transmission.
      #
      # @return [Hash] Serialized span data
      def to_h
        {
          span_id: span_id,
          trace_id: trace_id,
          parent_span_id: parent_span_id,
          name: name,
          type: span_type,
          start_time: start_time.iso8601(6),
          end_time: end_time&.iso8601(6),
          duration_ms: duration_ms,
          status: status,
          status_message: status_message,
          attributes: attributes,
          tokens: tokens,
          events: events,
          children: children.map(&:to_h)
        }
      end

      # Executes a block and records timing/errors.
      #
      # @yield Block to execute within the span
      # @return [Object] Result of the block
      def measure
        result = yield
        set_status(:ok)
        result
      rescue StandardError => e
        record_error(e)
        raise
      ensure
        finish
      end
    end
  end
end
