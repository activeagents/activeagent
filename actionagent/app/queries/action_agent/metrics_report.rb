# frozen_string_literal: true

module ActionAgent
  # The Metrics view's service overview: one window of traces bucketed into
  # a time series, plus the totals, previous-period deltas, top lists and
  # chart markers the golden-signal tiles, chart panels and right rail draw.
  #
  # The window is read once (TelemetryTrace.pluck_metrics_rows) and then
  # bucketed, classified and percentiled in Ruby, so PostgreSQL and SQLite
  # produce the same numbers. The previous period is read the same way for
  # the deltas, and the tools rail is one grouped read over tool spans.
  # Latency is the trace's total_duration_ms (nearest-rank percentiles);
  # cost is ModelPricing's estimate per trace from the first llm span's
  # model.
  class MetricsReport
    # range => [bucket seconds, bucket count]
    RANGES = {
      "1h" => [ 60, 60 ],
      "24h" => [ 900, 96 ],
      "7d" => [ 7200, 84 ]
    }.freeze
    DEFAULT_RANGE = "24h"
    CUSTOM_RANGE = "custom"
    MAX_WINDOW_HOURS = 24 * 30

    # A bare `hours` window is cut into about this many buckets, using the
    # smallest of these sizes that gets there.
    TARGET_BUCKETS = 96
    BUCKET_SIZES = [ 60, 120, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400 ].freeze

    # Error classes in display order. classify_error decides in this order
    # too, except that "tool error" is read off span status rather than the
    # message and so is checked first.
    ERROR_TYPES = [ "429 rate limit", "timeout", "tool error", "provider 5xx", "other" ].freeze
    ERROR_PATTERNS = {
      "429 rate limit" => /\b429\b|rate.?limit|too many requests|quota/i,
      "timeout" => /timed?\s?out|timeout|deadline/i,
      "provider 5xx" => /\b5\d\d\b|overloaded|internal server error|bad gateway|service unavailable|upstream/i
    }.freeze

    TOP_MODELS = 8
    TOP_ACTIONS = 5
    TOP_TOOLS = 5

    # A bucket is the window's incident when it has at least this many
    # errors and an error rate at least this many times the window's.
    INCIDENT_MIN_ERRORS = 5
    INCIDENT_RATE_FACTOR = 2

    # One trace, as TelemetryTrace.pluck_metrics_rows returns it.
    Row = Struct.new(
      :timestamp, :agent_class, :agent_action, :duration_ms, :status, :error_message,
      :input_tokens, :output_tokens, :model, :provider, :tool_calls, :tool_errors
    )

    # Running totals for one slice of the window — the whole window, a
    # bucket, an agent, a model or an action. Every slice keeps the same
    # counters so one pass over the rows can feed all of them.
    class Tally
      attr_reader :requests, :errors, :errors_by_type, :errors_by_agent, :requests_by_agent,
                  :tokens_in, :tokens_out, :cost, :tool_calls, :tool_errors

      def initialize
        @requests = 0
        @durations = []
        @sorted = nil
        @errors = 0
        @errors_by_type = Hash.new(0)
        @errors_by_agent = Hash.new(0)
        @requests_by_agent = Hash.new(0)
        @tokens_in = 0
        @tokens_out = 0
        @cost = 0.0
        @tool_calls = 0
        @tool_errors = 0
      end

      # @param error_type [String, nil] one of ERROR_TYPES for an ERROR trace
      def add(row, error_type:, cost:)
        @requests += 1
        if row.duration_ms
          @durations << row.duration_ms
          @sorted = nil
        end
        @requests_by_agent[row.agent_class] += 1 if row.agent_class
        if error_type
          @errors += 1
          @errors_by_type[error_type] += 1
          @errors_by_agent[row.agent_class] += 1 if row.agent_class
        end
        @tokens_in += row.input_tokens.to_i
        @tokens_out += row.output_tokens.to_i
        @cost += cost
        @tool_calls += row.tool_calls.to_i
        @tool_errors += row.tool_errors.to_i
      end

      def tokens = @tokens_in + @tokens_out

      def error_rate = MetricsReport.rate(@errors, @requests)

      def tool_error_rate = MetricsReport.rate(@tool_errors, @tool_calls)

      # Nearest-rank percentile of the recorded durations, in whole
      # milliseconds; nil when nothing in the slice carried a duration.
      def percentile(pct)
        @sorted ||= @durations.sort
        MetricsReport.percentile(@sorted, pct)&.round
      end
    end

    Aggregate = Struct.new(:window, :buckets, :by_agent, :by_model, :by_action, keyword_init: true)

    # Which ERROR_TYPES class an ERROR trace belongs to, first match wins: a
    # tool span that errored makes it a tool error whatever the message
    # says, otherwise the message decides, and anything unrecognised is
    # "other".
    #
    # @param error_message [String, nil] the trace's error_message
    # @param tool_errors [Integer] how many of its tool spans errored
    def self.classify_error(error_message, tool_errors: 0)
      return "tool error" if tool_errors.to_i.positive?

      message = error_message.to_s
      ERROR_PATTERNS.each { |type, pattern| return type if message.match?(pattern) }
      "other"
    end

    # Nearest-rank percentile of +sorted+ (ascending): the value at rank
    # ceil(p/100 × n). nil for an empty list.
    def self.percentile(sorted, pct)
      return nil if sorted.empty?

      rank = (sorted.size * pct / 100.0).ceil
      sorted[rank.clamp(1, sorted.size) - 1]
    end

    # +part+ as a percentage of +whole+, two decimals; 0.0 when whole is 0.
    def self.rate(part, whole)
      whole.to_i.positive? ? (part.to_f / whole * 100).round(2) : 0.0
    end

    # [range, bucket_seconds, bucket_count, window_hours]. A named range
    # wins; a bare +hours+ is a custom window bucketed to about
    # TARGET_BUCKETS points; neither means the default range.
    def self.resolve_range(range, hours)
      if RANGES.key?(range.to_s)
        seconds, count = RANGES[range.to_s]
        return [ range.to_s, seconds, count, (seconds * count) / 3600 ]
      end
      return resolve_range(DEFAULT_RANGE, nil) if hours.blank?

      window_hours = hours.to_i.clamp(1, MAX_WINDOW_HOURS)
      window_seconds = window_hours * 3600
      bucket_count = ->(size) { (window_seconds.to_f / size).ceil }
      seconds = BUCKET_SIZES.find { |size| bucket_count.call(size) <= TARGET_BUCKETS } || BUCKET_SIZES.last
      [ CUSTOM_RANGE, seconds, bucket_count.call(seconds), window_hours ]
    end

    attr_reader :range, :bucket_seconds, :bucket_count, :window_hours, :agent

    # @param traces [ActiveRecord::Relation] every trace the caller can see
    # @param agents [ActiveRecord::Relation, Array<Agent>] the caller's
    #   agents, whose versions become deploy markers
    # @param range [String, nil] "1h" | "24h" | "7d"
    # @param hours [Integer, String, nil] a custom window, used when
    #   +range+ is absent or unknown
    # @param agent [String, nil] an agent_class to narrow everything to
    # @param now [Time] the end of the window
    def initialize(traces:, agents:, range: nil, hours: nil, agent: nil, now: Time.current)
      @traces = traces
      @agents = agents
      @agent = agent.presence
      @now = now
      @range, @bucket_seconds, @bucket_count, @window_hours = self.class.resolve_range(range, hours)
      @starts = trace_model.bucket_starts(now, @bucket_seconds, @bucket_count)
    end

    def window_minutes = (@bucket_seconds * @bucket_count) / 60

    def window_start = Time.at(@starts.first).utc

    # A little past +now+: the last bucket is the live one.
    def window_end = Time.at(@starts.last + @bucket_seconds).utc

    def previous_start = Time.at(@starts.first - (@bucket_seconds * @bucket_count)).utc

    def to_h
      {
        range: @range,
        bucket_seconds: @bucket_seconds,
        window_minutes: window_minutes,
        agent: @agent,
        environment: environment,
        totals: totals,
        deltas: deltas,
        series: series,
        agents: agents_rail,
        models: models_rail,
        actions: actions_rail,
        tools: tools_rail,
        errors_by_type: errors_by_type,
        markers: markers
      }
    end

    def totals
      window = current.window
      {
        requests: window.requests,
        requests_per_minute: (window.requests.to_f / window_minutes).round(2),
        p50_ms: window.percentile(50),
        p95_ms: window.percentile(95),
        p99_ms: window.percentile(99),
        errors: window.errors,
        error_rate: window.error_rate,
        tokens_in: window.tokens_in,
        tokens_out: window.tokens_out,
        tokens: window.tokens,
        cost: window.cost.round(4),
        cost_per_request: window.requests.positive? ? (window.cost / window.requests).round(6) : 0.0,
        tool_calls: window.tool_calls,
        tool_errors: window.tool_errors,
        tool_error_rate: window.tool_error_rate
      }
    end

    # Against the period of the same length just before the window. A
    # percentage change is nil when the previous value is 0 or absent; the
    # error-rate delta is in points and is nil only when the previous
    # period had no requests (no rate to compare against).
    def deltas
      window = current.window
      {
        requests_pct: percent_change(previous.requests, window.requests),
        p50_pct: percent_change(previous.percentile(50), window.percentile(50)),
        error_rate_pt: previous.requests.positive? ? (window.error_rate - previous.error_rate).round(2) : nil,
        tokens_pct: percent_change(previous.tokens, window.tokens),
        cost_pct: percent_change(previous.cost, window.cost)
      }
    end

    # One entry per bucket, oldest first. Percentiles are nil for a bucket
    # with no requests; errors_by_type always carries every ERROR_TYPES
    # key so stacked bars have a stable shape.
    def series
      current.buckets.each_with_index.map do |bucket, index|
        {
          ts: Time.at(@starts[index]).utc.iso8601,
          requests: bucket.requests,
          requests_by_agent: bucket.requests_by_agent,
          p50_ms: bucket.percentile(50),
          p95_ms: bucket.percentile(95),
          p99_ms: bucket.percentile(99),
          errors: bucket.errors,
          errors_by_type: ERROR_TYPES.to_h { |type| [ type, bucket.errors_by_type[type] ] },
          tokens_in: bucket.tokens_in,
          tokens_out: bucket.tokens_out,
          cost: bucket.cost.round(4),
          tool_calls: bucket.tool_calls,
          tool_errors: bucket.tool_errors
        }
      end
    end

    # Requests descending. Traces with no agent_class are counted in the
    # totals but have no row here: a row is a filter target, and there is
    # no agent_class to filter by.
    def agents_rail
      total = current.window.requests
      current.by_agent.map do |name, tally|
        {
          name: name,
          requests: tally.requests,
          share_pct: self.class.rate(tally.requests, total),
          p95_ms: tally.percentile(95),
          error_rate: tally.error_rate,
          cost: tally.cost.round(4),
          tokens: tally.tokens
        }
      end.sort_by { |row| [ -row[:requests], row[:name] ] }
    end

    # Tokens descending, top TOP_MODELS; share is of the window's tokens.
    def models_rail
      total = current.window.tokens
      current.by_model.map do |(model, provider), tally|
        {
          model: model,
          provider: provider,
          requests: tally.requests,
          tokens: tally.tokens,
          share_pct: self.class.rate(tally.tokens, total),
          cost: tally.cost.round(4)
        }
      end.sort_by { |row| [ -row[:tokens], -row[:requests], row[:model] ] }.first(TOP_MODELS)
    end

    # p95 descending, top TOP_ACTIONS. An action none of whose traces
    # carried a duration cannot be ranked and is left out.
    def actions_rail
      current.by_action.filter_map do |(agent_class, action), tally|
        p95 = tally.percentile(95)
        next unless p95

        { name: "#{agent_class}##{action}", agent: agent_class, requests: tally.requests, p95_ms: p95 }
      end.sort_by { |row| [ -row[:p95_ms], -row[:requests], row[:name] ] }.first(TOP_ACTIONS)
    end

    # Calls descending, top TOP_TOOLS, from the window's tool spans.
    def tools_rail
      trace_model.tool_span_stats(window_scope).map do |name, stats|
        calls = stats[:calls].to_i
        {
          name: name,
          calls: calls,
          avg_ms: calls.positive? ? (stats[:total_ms].to_f / calls).round : 0,
          error_rate: self.class.rate(stats[:errors], calls)
        }
      end.sort_by { |row| [ -row[:calls], row[:name] ] }.first(TOP_TOOLS)
    end

    # Every ERROR_TYPES class in order, zero counts included.
    def errors_by_type
      ERROR_TYPES.map { |type| { type: type, count: current.window.errors_by_type[type] } }
    end

    # Deploys (agent versions created inside the window) and at most one
    # incident (the bucket with the error spike), by time. Ruby's sort is
    # not stable, so ties (versions saved in the same second) keep their
    # creation order explicitly.
    def markers
      (deploy_markers + incident_markers)
        .each_with_index
        .sort_by { |marker, position| [ marker[:ts], position ] }
        .map(&:first)
    end

    # The environment most of the window's traces report, nil when none do.
    def environment
      counts = window_scope.group(:environment).count.reject { |env, _count| env.blank? }
      counts.min_by { |env, count| [ -count, env ] }&.first
    end

    private

    def trace_model = ActionAgent.trace_model

    def window_scope = narrowed(@traces.where(timestamp: window_start...window_end))

    def previous_scope = narrowed(@traces.where(timestamp: previous_start...window_start))

    def narrowed(scope) = @agent ? scope.where(agent_class: @agent) : scope

    # The one pass over the window: every row feeds the window total, its
    # bucket, its agent, its model and its action.
    def current
      @current ||= begin
        aggregate = Aggregate.new(
          window: Tally.new,
          buckets: Array.new(@bucket_count) { Tally.new },
          by_agent: Hash.new { |hash, key| hash[key] = Tally.new },
          by_model: Hash.new { |hash, key| hash[key] = Tally.new },
          by_action: Hash.new { |hash, key| hash[key] = Tally.new }
        )

        rows_for(window_scope).each do |row|
          index = bucket_index(row.timestamp)
          next unless index

          error_type = error_type_for(row)
          cost = cost_for(row)

          aggregate.window.add(row, error_type: error_type, cost: cost)
          aggregate.buckets[index].add(row, error_type: error_type, cost: cost)
          aggregate.by_agent[row.agent_class].add(row, error_type: error_type, cost: cost) if row.agent_class
          aggregate.by_model[[ row.model || "unknown", row.provider ]].add(row, error_type: error_type, cost: cost)
          if row.agent_class && row.agent_action
            aggregate.by_action[[ row.agent_class, row.agent_action ]].add(row, error_type: error_type, cost: cost)
          end
        end

        aggregate
      end
    end

    # The previous period only feeds the deltas, so one tally is enough.
    def previous
      @previous ||= rows_for(previous_scope).each_with_object(Tally.new) do |row, tally|
        tally.add(row, error_type: error_type_for(row), cost: cost_for(row))
      end
    end

    def rows_for(scope)
      trace_model.pluck_metrics_rows(scope).map { |values| Row.new(*values) }
    end

    def bucket_index(timestamp)
      index = (trace_model.bucket_epoch(timestamp, @bucket_seconds) - @starts.first) / @bucket_seconds
      index if index >= 0 && index < @bucket_count
    end

    def error_type_for(row)
      return nil unless row.status == TelemetryTrace::STATUS_ERROR

      self.class.classify_error(row.error_message, tool_errors: row.tool_errors)
    end

    def cost_for(row)
      ModelPricing.estimate(model: row.model, input_tokens: row.input_tokens, output_tokens: row.output_tokens) || 0.0
    end

    def percent_change(before, after)
      return nil if before.nil? || after.nil? || before.to_f.zero?

      (((after.to_f - before.to_f) / before.to_f) * 100).round(2)
    end

    # One marker per agent version created inside the window, for the
    # caller's agents (narrowed to the filtered agent's versions when a
    # filter is on). A version that changed the instructions is labelled
    # as such — that is the deploy a latency or error shift most often
    # traces back to.
    #
    # The comparison needs each version's predecessor. Two reads cover
    # them all: the window's versions, then the predecessors that fall
    # before the window (a predecessor inside it is already loaded).
    # Version numbers are sequential per agent — Agent creates each one
    # as latest + 1 and they are only destroyed with their agent — so the
    # predecessor of version n is version n - 1.
    def deploy_markers
      agent_ids = @agents.respond_to?(:pluck) ? @agents.pluck(:id) : Array(@agents).map(&:id)
      versions = AgentVersion
        .includes(:agent)
        .where(agent_id: agent_ids, created_at: window_start...window_end)
        .order(:created_at, :id)
        .to_a
      predecessors = predecessors_of(versions)

      versions.filter_map do |version|
        agent = version.agent
        next if agent.nil?
        next if @agent && agent.telemetry_agent_class != @agent

        previous = predecessors[[ version.agent_id, version.version_number - 1 ]]
        instructions_changed = snapshot_of(version)["instructions"].to_s != snapshot_of(previous)["instructions"].to_s
        {
          kind: "deploy",
          ts: version.created_at.utc.iso8601,
          label: "#{instructions_changed ? 'instructions ' : ''}v#{version.version_number} · #{agent.name}",
          agent: agent.name
        }
      end
    end

    # { [agent_id, version_number] => version } holding the predecessor of
    # every version in +versions+: the ones among them, plus one read for
    # the rest.
    def predecessors_of(versions)
      loaded = versions.index_by { |version| [ version.agent_id, version.version_number ] }
      missing = versions
        .map { |version| [ version.agent_id, version.version_number - 1 ] }
        .reject { |key| key.last < 1 || loaded.key?(key) }
      return loaded if missing.empty?

      missing
        .group_by(&:first)
        .map { |agent_id, keys| AgentVersion.where(agent_id: agent_id, version_number: keys.map(&:last)) }
        .reduce(:or)
        .each_with_object(loaded) { |version, map| map[[ version.agent_id, version.version_number ]] = version }
    end

    # Snapshots are written with symbol keys and read back with strings.
    def snapshot_of(version)
      (version&.configuration_snapshot || {}).to_h.transform_keys(&:to_s)
    end

    # The bucket with the most errors, when it is a real spike: at least
    # INCIDENT_MIN_ERRORS errors and INCIDENT_RATE_FACTOR times the window's
    # error rate. Labelled by its dominant error class and attributed to
    # the agent that errored most in it.
    def incident_markers
      window_rate = current.window.error_rate
      return [] unless window_rate.positive?

      buckets = current.buckets
      index = buckets.each_index.max_by { |i| [ buckets[i].errors, -i ] }
      bucket = buckets[index]
      return [] if bucket.errors < INCIDENT_MIN_ERRORS
      return [] if bucket.error_rate < window_rate * INCIDENT_RATE_FACTOR

      type, _position = ERROR_TYPES.each_with_index.max_by { |name, i| [ bucket.errors_by_type[name], -i ] }
      agent_class, _count = bucket.errors_by_agent.min_by { |name, count| [ -count, name ] }

      [ { kind: "incident", ts: Time.at(@starts[index]).utc.iso8601, label: "#{type} spike", agent: agent_class } ]
    end
  end
end
