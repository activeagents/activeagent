# frozen_string_literal: true

module ActionAgent
  # Reconstructs a conversation stream from a telemetry trace, in the shape the
  # dashboard's Interactions view already renders for platform-executed agents.
  #
  # Interactions normally reads solid_agent persistence (AgentContext /
  # AgentMessage / AgentGeneration), which only exists for agents the platform
  # ran itself. Agents running inside a customer's own app — a RubyLLM chat
  # reporting through the telemetry endpoint, say — never write those tables, so
  # the view was blind to them.
  #
  # The spans carry the same story when the reporter opts into content capture:
  # the llm span holds `llm.prompt` / `llm.instructions` / `llm.completion`, and
  # each tool span holds `tool.arguments` / `tool.result`. Ordering them by start
  # time yields prompt → tool call → tool result → response.
  class TraceInteractionSerializer
    def self.summary(trace)
      new(trace).summary
    end

    def self.detail(trace)
      new(trace).detail
    end

    def initialize(trace)
      @trace = trace
      @spans = Array(trace.spans)
    end

    def summary
      {
        id: "trace-#{@trace.id}",
        source: "telemetry",
        agent_name: @trace.agent_class,
        action_name: @trace.agent_action,
        display_name: @trace.display_name,
        agent: nil,
        service_name: @trace.service_name,
        environment: @trace.environment,
        model: @trace.model,
        tokens: {
          input: @trace.total_input_tokens,
          output: @trace.total_output_tokens,
          total: @trace.total_input_tokens.to_i + @trace.total_output_tokens.to_i
        },
        message_count: messages.size,
        # Tool activity is known even when content capture is off, so a run
        # reported without prompts still shows what it did.
        tool_count: tool_spans.size,
        duration_ms: @trace.total_duration_ms&.to_f,
        generation_count: llm_spans.size,
        created_at: @trace.timestamp.iso8601,
        last_activity_at: @trace.timestamp.iso8601
      }
    end

    def detail
      summary.merge(
        instructions: llm_attribute("llm.instructions") || any_attribute("prompt.input.instructions"),
        messages: messages,
        generations: generations
      )
    end

    private

    # The generation span. Older traces wrapped a separate `llm` span inside a
    # root; newer ones merge them, since the provider loop *is* the interaction.
    # Accept both, and never count the same generation twice.
    def llm_spans
      @llm_spans ||= begin
        nested = @spans.select { |span| span["type"] == "llm" }
        nested.presence || @spans.select { |span| span["parent_span_id"].nil? && span.dig("attributes", "llm.model") }
      end
    end

    def tool_spans
      @tool_spans ||= @spans.select { |span| span["type"] == "tool" }
                            .sort_by { |span| span["start_time"].to_s }
    end

    def llm_attribute(key)
      llm_spans.filter_map { |span| span.dig("attributes", key).presence }.first
    end

    # ActiveAgent's instrumentation puts prompt contents on the prompt span
    # (RubyLLM puts everything on the llm span) — accept either home.
    def any_attribute(key)
      @spans.filter_map { |span| span.dig("attributes", key).presence }.first
    end

    # ActiveAgent reports the outbound conversation as a JSON array of
    # {role, content} on the prompt span rather than a single llm.prompt.
    def outbound_messages
      raw = any_attribute("prompt.input.messages")
      return [] if raw.blank?

      entries = JSON.parse(raw)
      entries.is_a?(Array) ? entries.select { |m| m.is_a?(Hash) && m["content"].present? } : []
    rescue JSON::ParserError
      []
    end

    # prompt → (tool call → tool result)* → completion. Tool pairs are ordered by
    # span start time, so the stream reads the way the run actually happened.
    def messages
      @messages ||= begin
        stream = []
        index = 0
        prompt_span = @spans.find { |span| span["type"] == "prompt" }

        if (prompt = llm_attribute("llm.prompt"))
          stream << message(index += 1, role: "user", content: prompt, at: @trace.timestamp, timing: timing_for(prompt_span))
        else
          outbound_messages.each do |entry|
            stream << message(index += 1, role: entry["role"].presence || "user", content: entry["content"], at: @trace.timestamp, timing: timing_for(prompt_span))
          end
        end

        tool_spans.each do |span|
          name = span.dig("attributes", "tool.name")
          call_id = span.dig("attributes", "tool.call_id")
          started = parse_time(span["start_time"]) || @trace.timestamp
          finished = parse_time(span["end_time"]) || started

          stream << message(
            index += 1, role: "assistant", content: nil, at: started,
            tool_name: name, tool_call_id: call_id,
            tool_calls: parsed(span.dig("attributes", "tool.arguments") || span.dig("attributes", "tool.input.args")),
            timing: timing_for(span)
          )
          stream << message(
            index += 1, role: "tool",
            content: span.dig("attributes", "tool.result") || span.dig("attributes", "tool.output.result"),
            at: finished,
            tool_name: name, tool_call_id: call_id,
            timing: timing_for(span)
          )
        end

        if (completion = llm_attribute("llm.completion") || llm_attribute("llm.output.message"))
          stream << message(index += 1, role: "assistant", content: completion, at: end_time, timing: timing_for(llm_spans.first))
        end

        stream
      end
    end

    # Where a message's span sits on the trace's wall clock — lets the
    # conversation view double as a waterfall (span-message pill bars).
    def trace_start
      @trace_start ||= @spans.filter_map { |span| parse_time(span["start_time"]) }.min
    end

    def timing_for(span)
      return {} unless span

      start = parse_time(span["start_time"])
      offset = (start && trace_start) ? ((start - trace_start) * 1000.0).round(2) : 0
      {
        span_start_ms: [ offset, 0 ].max,
        span_duration_ms: span["duration_ms"]&.to_f&.round(2) || 0,
        trace_duration_ms: @trace.total_duration_ms&.to_f&.round(2)
      }
    end

    def message(index, role:, content:, at:, tool_name: nil, tool_call_id: nil, tool_calls: nil, timing: nil)
      {
        id: "#{@trace.id}-#{index}",
        role: role,
        content: content,
        tool_name: tool_name,
        tool_call_id: tool_call_id,
        tool_calls: tool_calls,
        content_checksum: nil,
        created_at: at.iso8601(3),
        **(timing || {})
      }
    end

    def generations
      llm_spans.map.with_index(1) do |span, index|
        attributes = span["attributes"] || {}
        tokens = span["tokens"] || {}

        {
          id: "#{@trace.id}-llm-#{index}",
          model: attributes["llm.model"],
          provider: attributes["llm.provider"],
          finish_reason: span["status"] == "ERROR" ? "error" : attributes["llm.finish_reason"],
          tokens: {
            input: tokens["input"].to_i,
            output: tokens["output"].to_i,
            total: tokens.values_at("input", "output", "thinking").compact.sum(&:to_i),
            cached: 0,
            thinking: tokens["thinking"].to_i
          },
          cache_hit: false,
          thinking: tokens["thinking"].to_i.positive?,
          duration_seconds: span["duration_ms"] ? (span["duration_ms"].to_f / 1000).round(3) : nil,
          trace_id: @trace.trace_id,
          created_at: (parse_time(span["start_time"]) || @trace.timestamp).iso8601(3)
        }
      end
    end

    # Tool arguments arrive JSON-encoded; hand the view an object when possible
    # so it renders structurally rather than as an escaped string.
    def parsed(value)
      return nil if value.blank?

      JSON.parse(value)
    rescue JSON::ParserError
      value
    end

    def end_time
      parse_time(llm_spans.first&.dig("end_time")) || @trace.timestamp
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
