# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # One agent execution, whoever ran it.
    #
    # The platform records executions it initiates as AgentRun rows; agents
    # running inside a customer's own app only ever produce a TelemetryTrace.
    # They are the same grain — one attempt at one agent action — so the
    # dashboard treats them as one list with a `source` discriminator rather
    # than as two competing tabs:
    #
    #   dashboard — an AgentRun (we executed it; has lifecycle, logs, cancel)
    #   reported  — a trace no AgentRun claims (their app executed it)
    #
    # A platform execution usually writes BOTH an AgentRun and a trace sharing a
    # trace_id, so traces are counted only when unclaimed. The reverse is not
    # symmetric: a run that fails before its root span exists has no trace at
    # all, which is why runs — not traces — are the authoritative source when
    # both exist.
    #
    # Distinct from AgentContext, which is a *stream*: one durable conversation
    # per agent action that many executions append to. A stream is a parent of
    # executions, not an alternative to them.
    class AgentExecutions
      SOURCES = %w[dashboard reported].freeze

      # What to rank a list of executions by. "Popular" is deliberately absent:
      # it's an aggregate property of an agent or a model, not of one attempt —
      # the agent list and the metrics table sort by it, this list can't.
      SORTS = {
        "recent" => "Most recent",
        "longest" => "Longest running",
        "cost" => "Highest cost",
        "tokens" => "Most tokens"
      }.freeze
      DEFAULT_SORT = "recent"

      Row = Struct.new(
        :id, :source, :status, :occurred_at, :duration_ms, :tokens,
        :input_tokens, :output_tokens, :cost,
        :trace_id, :agent_id, :action_name, :provider, :model,
        :input_preview, :output_preview, :error_message,
        keyword_init: true
      ) do
        def as_json(*)
          to_h.transform_values { |value| value.is_a?(Time) ? value.iso8601(3) : value }
        end

        # Runs are addressable by record id; reported executions only by trace.
        def to_param
          source == "dashboard" ? id.to_s : "trace-#{id}"
        end
      end

      # @param agents [ActiveRecord::Relation, Array<Agent>] scope to these agents
      # @param owner [Object, nil] tenant whose reported traces are in scope;
      #   nil in a single-tenant install, where every trace is in scope
      # @param window_minutes [Integer, nil] nil means all time
      # @param source [String, nil] "dashboard" | "reported" | nil for both
      # @param status [String, nil] AgentRun status; also filters reported by OK/ERROR
      # @param sort [String, nil] one of SORTS; unknown values fall back to recent
      def initialize(agents:, owner: nil, window_minutes: nil, source: nil, status: nil, sort: nil)
        @agent_ids = Array(agents.respond_to?(:pluck) ? agents.pluck(:id) : agents.map(&:id))
        @owner = owner
        @window_minutes = window_minutes
        @source = source.presence
        @status = status.presence
        @sort = SORTS.key?(sort.to_s) ? sort.to_s : DEFAULT_SORT
      end

      # Ranked by the chosen dimension, descending. The two sources can only be
      # ordered together in Ruby (no SQL union), which is also why this always
      # ranks the whole window rather than the page.
      def page(page: 1, per_page: 20)
        all = sorted_rows
        offset = (page.to_i - 1) * per_page.to_i
        { rows: all[offset, per_page.to_i] || [], total: all.size }
      end

      def sorted_rows
        # Ties (and rows missing the sorted value entirely — an execution still
        # running has no duration) fall back to newest first, so the list never
        # reorders arbitrarily between requests.
        rows.sort_by { |row| [ -sort_value(row), -(row.occurred_at || Time.at(0)).to_f ] }
      end

      def rows
        @rows ||= (include_dashboard? ? run_rows : []) + (include_reported? ? trace_rows : [])
      end

      # Traces attributed to these agents that no AgentRun already accounts for.
      # Shared with AgentScorecard so every surface counts the same executions.
      def self.unclaimed_traces(agent_ids, since: nil, owner: nil)
        traces = ActiveAgent::Dashboard.trace_model
        runs_table = AgentRun.table_name
        traces_table = traces.table_name

        scope = traces.where(agent_id: agent_ids)
        scope = scope.for_account(owner) if owner
        scope = scope.where(timestamp: since..) if since
        scope
          .joins(<<~SQL.squish)
            LEFT JOIN #{runs_table}
              ON #{runs_table}.trace_id = #{traces_table}.trace_id
             AND #{runs_table}.agent_id = #{traces_table}.agent_id
          SQL
          .where(runs_table => { id: nil })
      end

      private

      def sort_value(row)
        case @sort
        when "longest" then row.duration_ms.to_f
        when "cost" then row.cost.to_f
        when "tokens" then row.tokens.to_i
        else (row.occurred_at || Time.at(0)).to_f
        end
      end

      def include_dashboard? = @source.nil? || @source == "dashboard"
      # A single-tenant dashboard reads every trace it holds. A multi-tenant
      # one has no business reading any without a tenant to scope them to.
      def include_reported?
        return false if ActiveAgent::Dashboard.multi_tenant? && @owner.nil?

        @source.nil? || @source == "reported"
      end

      def since = @window_minutes ? @window_minutes.to_i.minutes.ago : nil

      def run_rows
        scope = AgentRun.where(agent_id: @agent_ids)
        scope = scope.where(created_at: since..) if since
        scope = scope.where(status: @status) if @status

        scope.map do |run|
          model = run.output_metadata&.dig("model")
          Row.new(
            id: run.id,
            source: "dashboard",
            status: run.status,
            occurred_at: run.created_at,
            duration_ms: run.calculated_duration_ms,
            tokens: run.total_tokens.to_i,
            input_tokens: run.input_tokens.to_i,
            output_tokens: run.output_tokens.to_i,
            cost: ModelPricing.estimate(
              model: model,
              input_tokens: run.input_tokens,
              output_tokens: run.output_tokens
            ),
            trace_id: run.trace_id,
            agent_id: run.agent_id,
            action_name: run.action_name,
            provider: run.output_metadata&.dig("provider"),
            model: model,
            input_preview: run.input_prompt.to_s.truncate(160),
            output_preview: run.output.to_s.truncate(160).presence,
            error_message: run.error_message
          )
        end
      end

      def trace_rows
        scope = self.class.unclaimed_traces(@agent_ids, since: since, owner: @owner)
        # A run status filter has no exact analogue on a trace; map the two that
        # do rather than silently ignoring the filter.
        scope = scope.where(status: "ERROR") if @status == "failed"
        scope = scope.where.not(status: "ERROR") if @status == "complete"
        return [] if @status.present? && !%w[failed complete].include?(@status)

        scope.map do |trace|
          model = trace.model
          Row.new(
            id: trace.id,
            source: "reported",
            status: trace.status == "ERROR" ? "failed" : "complete",
            occurred_at: trace.timestamp,
            duration_ms: trace.total_duration_ms&.round,
            tokens: trace.total_tokens.to_i,
            input_tokens: trace.total_input_tokens.to_i,
            output_tokens: trace.total_output_tokens.to_i,
            cost: ModelPricing.estimate(
              model: model,
              input_tokens: trace.total_input_tokens,
              output_tokens: trace.total_output_tokens
            ),
            trace_id: trace.trace_id,
            agent_id: trace.agent_id,
            action_name: trace.agent_action,
            provider: trace.provider,
            model: model,
            input_preview: nil,
            output_preview: nil,
            error_message: trace.error_message
          )
        end
      end
    end
  end
end
