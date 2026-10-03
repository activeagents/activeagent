# frozen_string_literal: true

module ActionAgent
  # Used to build the timeline of a session: a conversation, a run or a
  # recording, with what happened in it laid out in lanes on one time axis.
  #
  # Lanes:
  #   message  the conversation's messages
  #   llm      model calls: the trace's llm spans when the trace is stored,
  #            else the run's llm events (agent_runs.logs), else generations
  #   tool     tool calls: the trace's tool spans when the trace is stored,
  #            else the run's tool events, else tool messages
  #   browser  what the session's recordings captured: recording events
  #            other than rrweb, and the legacy recording actions
  #
  # Every entry has an `id`, its `lane`, an absolute `start` (ISO 8601 with
  # milliseconds), a `duration_ms` and the `trace_id` it belongs to, nil when
  # unknown. Each lane is in time order. rrweb events are not in the
  # timeline: they are read page by page from the recording's events
  # endpoint, and `recordings` says how many there are.
  #
  # A session reaches its runs, conversations and traces only through ids
  # the server set (a recording's agent_run_id and agent_context_id, a run's
  # trace_id), each looked up within the caller's Scope. Ids inside event
  # payloads are shown, never followed. Browser tool calls are shown with
  # their typed values masked (BrowserToolRedaction), and no entry carries
  # SessionRecording::SENSITIVE_STATE_KEYS.
  class SessionTimeline
    # What the caller may reach:
    #   agents      the caller's agents (Api::BaseController#owner_agents)
    #   traces      the caller's telemetry traces
    #   recordings  the recordings the caller may open
    Scope = Struct.new(:agents, :traces, :recordings, keyword_init: true)

    TEXT_LIMIT = 4000
    LANE_LIMIT = 2000
    # Recording event rows loaded per query while the browser lane is filled.
    BROWSER_ROWS_PER_QUERY = 20
    RUN_LOG_KINDS = { "llm" => %w[llm], "tool" => %w[tool agent] }.freeze
    # What the llm lane reads from a generation; its raw response is not.
    GENERATION_COLUMNS = %i[id agent_context_id trace_id model provider finish_reason input_tokens output_tokens
      duration_seconds created_at].freeze

    # The timeline of +context+, an AgentContext the caller owns: its
    # messages, the runs and traces of its generations, and the recordings
    # linked to the conversation or to one of those runs.
    def self.for_context(context, scope, recordings: nil)
      trace_ids = context.generations.where.not(trace_id: [ nil, "" ]).distinct.pluck(:trace_id)
      runs = trace_ids.any? ? AgentRun.where(agent: scope.agents, trace_id: trace_ids).to_a : []
      recordings ||= scope.recordings.where(agent_context_id: context.id)
        .or(scope.recordings.where(agent_run_id: runs.map(&:id)))

      new(
        scope, kind: "context", id: context.id,
        contexts: [ context ], runs: runs, trace_ids: trace_ids,
        messages: context.messages.chronological.to_a,
        generations: context.generations.select(*GENERATION_COLUMNS).to_a,
        recordings: recordings
      )
    end

    # The timeline of +run+, an AgentRun the caller owns: its trace, its
    # slice of the conversations its generations were written to, and the
    # recordings linked to it.
    def self.for_run(run, scope, recordings: nil)
      contexts = AgentContext.for_agents(scope.agents)
        .where(id: AgentGeneration.where(trace_id: run.trace_id).select(:agent_context_id)).to_a
      messages = contexts.flat_map { |context| run_slice(context.messages.chronological.to_a, run) }

      new(
        scope, kind: "run", id: run.id,
        contexts: contexts, runs: [ run ], trace_ids: [ run.trace_id ],
        messages: messages,
        generations: AgentGeneration.where(trace_id: run.trace_id, agent_context_id: contexts.map(&:id))
          .select(*GENERATION_COLUMNS).to_a,
        recordings: recordings || scope.recordings.where(agent_run_id: run.id)
      )
    end

    # The timeline of +recording+, one the caller may open: its own browser
    # lane, with the lanes of its conversation when it has one the caller
    # owns, else of its run.
    def self.for_recording(recording, scope)
      context = recording.agent_context_id && AgentContext.for_agents(scope.agents).find_by(id: recording.agent_context_id)
      run = recording.agent_run_id && AgentRun.where(agent: scope.agents).find_by(id: recording.agent_run_id)

      timeline =
        if context then for_context(context, scope, recordings: [ recording ])
        elsif run then for_run(run, scope, recordings: [ recording ])
        else new(scope, kind: "recording", id: recording.id, recordings: [ recording ])
        end
      timeline.retitle("recording", recording.id)
    end

    # The messages of +run+ in a conversation: from the user message stamped
    # with the run's trace id up to the next user message stamped with
    # another, as the run detail shows them. A run whose user message carries
    # no trace id gets the messages written while it ran.
    def self.run_slice(messages, run)
      start = messages.index { |message| message.role == "user" && message.provenance&.dig("trace_id") == run.trace_id }
      return messages.select { |message| written_during?(message, run) } unless start

      slice = [ messages[start] ]
      messages[(start + 1)..].each do |message|
        trace = message.provenance&.dig("trace_id")
        break if message.role == "user" && trace.present? && trace != run.trace_id

        slice << message
      end
      slice
    end

    def self.written_during?(message, run)
      started = run.started_at || run.created_at
      finished = run.completed_at || Time.current
      message.created_at.between?(started, finished)
    end

    def initialize(scope, kind:, id:, contexts: [], runs: [], trace_ids: [], messages: [], generations: [], recordings: [])
      @scope = scope
      @kind = kind
      @id = id
      @contexts = contexts
      @runs = runs
      @trace_ids = trace_ids.compact.uniq
      @messages = messages
      @generations = generations
      @recordings = recordings.to_a
    end

    # Names the session as the caller addressed it, and returns the timeline.
    def retitle(kind, id)
      @kind = kind
      @id = id
      self
    end

    # The timeline as the JSON API returns it.
    # @return [Hash]
    def as_json(*)
      full = { message: message_lane, llm: llm_lane, tool: tool_lane, browser: browser_lane }
      lanes = full.transform_values { |entries| entries.first(LANE_LIMIT) }
      entries = lanes.values.flatten
      starts = entries.map { |entry| Time.iso8601(entry[:start]) }
      ends = entries.zip(starts).map { |entry, start| start + (entry[:duration_ms].to_f / 1000) }

      SessionRecording.without_sensitive_state(
        session: {
          kind: @kind,
          id: @id,
          started_at: starts.min&.then { |start| timestamp(start) },
          ended_at: ends.max&.iso8601(3),
          trace_ids: @trace_ids,
          agent_run_ids: @runs.map(&:id),
          agent_context_ids: @contexts.map(&:id),
          truncated: full.values.any? { |lane| lane.size > LANE_LIMIT }
        },
        lanes: lanes,
        recordings: @recordings.map { |recording| recording_summary(recording) }
      )
    end

    private

    # --- message lane --------------------------------------------------------

    def message_lane
      current_trace = nil
      @messages.map do |message|
        stamped = message.provenance&.dig("trace_id")
        current_trace = stamped if message.role == "user" && stamped.present?
        message_entry(message, stamped.presence || current_trace)
      end.sort_by { |entry| entry[:start] }
    end

    def message_entry(message, trace_id)
      browser_tool = message.role == "tool" ? message.tool_name : nil
      {
        id: "message-#{message.id}",
        lane: "message",
        role: message.role,
        content: clip(BrowserToolRedaction.redact_text(browser_tool, message.content.to_s, message.tool_arguments)),
        tool_name: message.tool_name,
        tool_call_id: message.tool_call_id,
        tool_calls: message.tool_calls_data.map { |call| tool_call_entry(call) },
        start: timestamp(message.created_at),
        duration_ms: 0
      }.compact.merge(trace_id: trace_id)
    end

    def tool_call_entry(call)
      return call unless call.is_a?(Hash)

      call = call.stringify_keys
      call.merge("arguments" => BrowserToolRedaction.redact_arguments(call["name"], call["arguments"]))
    end

    # --- llm and tool lanes --------------------------------------------------

    def llm_lane
      lane_for("llm") do |trace_id|
        generations_by_trace.fetch(trace_id, []).map { |generation| generation_entry(generation) }
      end
    end

    def tool_lane
      lane_for("tool") do |trace_id|
        tool_messages_by_trace.fetch(trace_id, []).map { |message| tool_message_entry(message, trace_id) }
      end
    end

    # The +lane+ entries of every trace in the session: from the stored
    # trace's spans, else the run's events, else what the block derives from
    # the persisted conversation. A stored trace is the whole record of its
    # tool calls, so a trace with no tool spans made none. A trace with no llm
    # spans comes from a reporter that does not trace model calls, and the
    # other sources stand in.
    def lane_for(lane, &fallback)
      @trace_ids.flat_map do |trace_id|
        span_entries = spans_by_trace.key?(trace_id) ? span_entries(lane, trace_id) : []
        next span_entries if span_entries.any? || (lane == "tool" && spans_by_trace.key?(trace_id))

        run_entries = run_event_entries(lane, trace_id)
        run_entries.any? ? run_entries : fallback.call(trace_id)
      end.sort_by { |entry| entry[:start] }
    end

    def span_entries(lane, trace_id)
      spans = spans_by_trace[trace_id]
      selected =
        if lane == "llm"
          nested = spans.select { |span| span["type"] == "llm" }
          nested.presence || spans.select { |span| span["parent_span_id"].nil? && span.dig("attributes", "llm.model") }
        else
          spans.select { |span| span["type"] == "tool" }
        end
      selected.filter_map { |span| span_entry(lane, span, trace_id) }
    end

    def span_entry(lane, span, trace_id)
      started = parse_time(span["start_time"])
      return nil unless started

      attributes = span["attributes"] || {}
      entry = {
        id: "span-#{span['span_id']}",
        lane: lane,
        name: span["name"],
        start: timestamp(started),
        duration_ms: span_duration(span, started),
        status: span["status"],
        trace_id: trace_id
      }

      if lane == "llm"
        entry.merge(
          model: attributes["llm.model"],
          provider: attributes["llm.provider"],
          finish_reason: attributes["llm.finish_reason"],
          tokens: span["tokens"]
        ).compact
      else
        name = attributes["tool.name"] || span["name"].to_s.delete_prefix("tool.")
        arguments = attributes["tool.input.args"] || attributes["tool.arguments"]
        result = attributes["tool.output.result"] || attributes["tool.result"]
        entry.merge(
          name: name,
          arguments: BrowserToolRedaction.redact_arguments(name, arguments),
          result: clip(BrowserToolRedaction.redact_text(name, result, arguments)),
          error: attributes["tool.error"] || span["status"] == TelemetryTrace::STATUS_ERROR
        ).compact
      end
    end

    def span_duration(span, started)
      return span["duration_ms"].to_f.round(3) if span["duration_ms"]

      finished = parse_time(span["end_time"])
      finished ? ((finished - started) * 1000).round(3) : 0
    end

    # The run's llm, or tool and agent, events: each a started event paired
    # with the done or error event of the same eid.
    def run_event_entries(lane, trace_id)
      run = runs_by_trace[trace_id]
      return [] unless run

      events = Array(run.logs).select { |event| event.is_a?(Hash) && RUN_LOG_KINDS.fetch(lane).include?(event["kind"]) && event["eid"] }
      events.group_by { |event| event["eid"] }.filter_map do |eid, pair|
        started = pair.find { |event| event["status"] == "started" }
        finished = pair.find { |event| event["status"] != "started" }
        run_event_entry(lane, eid, started, finished, trace_id)
      end
    end

    def run_event_entry(lane, eid, started, finished, trace_id)
      first = started || finished
      start = parse_time(first["at"])
      return nil unless start

      finished_at = started && parse_time(finished&.dig("at"))
      duration = finished&.dig("duration_ms") || (finished_at ? ((finished_at - start) * 1000).round : 0)
      name = first["label"].to_s
      arguments = started&.dig("detail")
      {
        id: "log-#{eid}",
        lane: lane,
        name: name,
        start: timestamp(started ? start : start - (duration.to_f / 1000)),
        duration_ms: duration,
        status: finished ? finished["status"] : "started",
        arguments: lane == "tool" ? BrowserToolRedaction.redact_arguments(name, arguments) : nil,
        detail: clip(BrowserToolRedaction.redact_text(name, finished&.dig("detail"), arguments)),
        trace_id: trace_id
      }.compact
    end

    def generation_entry(generation)
      duration = (generation.duration_seconds.to_f * 1000).round
      {
        id: "generation-#{generation.id}",
        lane: "llm",
        name: generation.model,
        model: generation.model,
        provider: generation.provider,
        finish_reason: generation.finish_reason,
        tokens: { input: generation.input_tokens, output: generation.output_tokens },
        start: timestamp(generation.created_at - (duration / 1000.0)),
        duration_ms: duration,
        trace_id: generation.trace_id
      }.compact
    end

    def tool_message_entry(message, trace_id)
      duration = message.metadata&.dig("duration_ms").to_f
      {
        id: "tool-message-#{message.id}",
        lane: "tool",
        name: message.tool_name,
        arguments: BrowserToolRedaction.redact_arguments(message.tool_name, message.tool_arguments),
        result: clip(BrowserToolRedaction.redact_text(message.tool_name, message.content.to_s, message.tool_arguments)),
        start: timestamp(message.created_at - (duration / 1000)),
        duration_ms: duration.round(3),
        trace_id: trace_id
      }.compact
    end

    # --- browser lane --------------------------------------------------------

    # The recordings' events and legacy actions in time order, read no further
    # than the earliest LANE_LIMIT + 1 of each: enough to fill the lane and to
    # tell whether it was cut short.
    def browser_lane
      return [] if @recordings.empty?

      (earliest_event_entries + earliest_action_entries).sort_by { |entry| entry[:start] }
    end

    # Each row holds at least one event, so the earliest LANE_LIMIT + 1 events
    # are in the first LANE_LIMIT + 1 rows in RecordingEvent.chronological
    # order. Those rows are decoded in that order until no unread row can
    # start before the last entry kept.
    def earliest_event_entries
      wanted = LANE_LIMIT + 1
      kept = []
      starts = RecordingEvent.where(session_recording_id: @recordings.map(&:id)).where.not(kind: "rrweb")
        .chronological.limit(wanted).pluck(:id, :occurred_from)

      starts.each_slice(BROWSER_ROWS_PER_QUERY) do |slice|
        rows = RecordingEvent.where(id: slice.map(&:first)).index_by(&:id)
        slice.each do |id, occurred_from|
          return kept if kept.size == wanted && timestamp(occurred_from) >= kept.last[:start]
          next unless rows[id]

          recording_event_entries(rows[id]).each { |entry| keep_earliest(kept, entry, wanted) }
        end
      end
      kept
    end

    # Adds +entry+ to +kept+, which stays in start order and holds at most
    # +limit+ entries.
    def keep_earliest(kept, entry, limit)
      return if kept.size == limit && entry[:start] >= kept.last[:start]

      index = kept.bsearch_index { |other| other[:start] > entry[:start] } || kept.size
      kept.insert(index, entry)
      kept.pop if kept.size > limit
    end

    def earliest_action_entries
      @recordings.flat_map do |recording|
        recording.recording_actions.ordered.limit(LANE_LIMIT + 1).map { |action| recording_action_entry(action, recording) }
      end
    end

    def recording_event_entries(row)
      row.events.each_with_index.map do |event, index|
        data = event["data"].is_a?(Hash) ? event["data"] : { "value" => event["data"] }
        if row.kind == "action"
          data = data.merge("parameters" => BrowserToolRedaction.redact_arguments(data["tool_name"], data["parameters"]))
        end
        {
          id: "event-#{row.id}-#{index}",
          lane: "browser",
          kind: row.kind,
          recording_id: row.session_recording_id,
          start: timestamp(RecordingEvent.time_at(event["at"].to_i)),
          duration_ms: data["duration_ms"] || 0,
          data: data
        }.compact.merge(trace_id: row.kind == "action" ? data["trace_id"] : nil)
      end
    end

    def recording_action_entry(action, recording)
      {
        id: "recording-action-#{action.id}",
        lane: "browser",
        kind: "action",
        recording_id: action.session_recording_id,
        start: timestamp(recording.created_at + (action.timestamp_ms.to_f / 1000)),
        duration_ms: 0,
        data: {
          "action_type" => action.action_type,
          "selector" => action.selector,
          "value" => action.redacted_value,
          "metadata" => action.safe_metadata
        }.compact,
        trace_id: nil
      }
    end

    def recording_summary(recording)
      {
        id: recording.id,
        name: recording.name,
        status: recording.status,
        source: recording.source,
        agent_run_id: recording.agent_run_id,
        agent_context_id: recording.agent_context_id,
        event_count: recording.event_count,
        dropped_event_count: recording.dropped_event_count,
        rrweb: {
          event_count: rrweb_totals[:event_count].fetch(recording.id, 0),
          first_at: rrweb_totals[:first_at][recording.id]&.iso8601(3),
          last_at: rrweb_totals[:last_at][recording.id]&.iso8601(3)
        },
        created_at: timestamp(recording.created_at)
      }
    end

    # The rrweb event count and time range of each recording, by recording id.
    def rrweb_totals
      @rrweb_totals ||= begin
        rows = RecordingEvent.where(session_recording_id: @recordings.map(&:id), kind: "rrweb").group(:session_recording_id)
        { event_count: rows.sum(:event_count), first_at: rows.minimum(:occurred_from), last_at: rows.maximum(:occurred_to) }
      end
    end

    # --- lookups -------------------------------------------------------------

    # Spans by trace id, for the session's traces the caller may read.
    def spans_by_trace
      @spans_by_trace ||= @trace_ids.empty? ? {} : @scope.traces.where(trace_id: @trace_ids).pluck(:trace_id, :spans)
        .each_with_object({}) { |(trace_id, spans), by_trace| (by_trace[trace_id] ||= []).concat(Array(spans)) }
    end

    def runs_by_trace
      @runs_by_trace ||= @runs.index_by(&:trace_id)
    end

    def generations_by_trace
      @generations_by_trace ||= @generations.group_by(&:trace_id)
    end

    def tool_messages_by_trace
      @tool_messages_by_trace ||= begin
        current_trace = nil
        @messages.each_with_object({}) do |message, by_trace|
          stamped = message.provenance&.dig("trace_id")
          current_trace = stamped if message.role == "user" && stamped.present?
          (by_trace[current_trace] ||= []) << message if message.role == "tool"
        end
      end
    end

    # --- helpers -------------------------------------------------------------

    def clip(text)
      return text unless text.is_a?(String)

      text.length > TEXT_LIMIT ? "#{text[0, TEXT_LIMIT]}…" : text
    end

    def timestamp(time)
      time.utc.iso8601(3)
    end

    def parse_time(value)
      value.present? ? Time.iso8601(value.to_s) : nil
    rescue ArgumentError
      nil
    end
  end
end
