# frozen_string_literal: true

module ActionAgent
  # Per-agent scorecard stats for the dashboard's agent cards, computed with
  # grouped queries (no per-agent N+1) over two sources:
  #
  # * agent_runs — executions the platform itself ran, and
  # * active_agent_telemetry_traces — executions reported by an SDK in the
  #   customer's own app, attributed to an Agent by AgentRegistrar.
  #
  # Agents discovered by observation (status: :observed) only ever have the
  # second kind, so a runs-only scorecard reported 0 for every tile while the
  # Traces view showed real traffic.
  #
  # A platform run writes BOTH an AgentRun and a trace sharing a trace_id, so
  # traces are counted only when no AgentRun claims the same trace_id —
  # otherwise every platform execution would count twice.
  class AgentScorecard
    WINDOW = 30.days

    # @param agents [Enumerable<Agent>]
    # @return [Hash{Integer => Hash}] agent_id => stats
    def self.for_agents(agents)
      ids = agents.map(&:id)
      return {} if ids.empty?

      window_start = WINDOW.ago
      windowed = AgentRun.where(agent_id: ids, created_at: window_start..)

      run_counts = windowed.group(:agent_id).count
      completed_counts = windowed.where(status: :complete).group(:agent_id).count
      avg_durations = windowed.where.not(duration_ms: nil).group(:agent_id).average(:duration_ms)
      token_sums = windowed.group(:agent_id).sum("COALESCE(total_tokens, 0)")
      last_runs = AgentRun.where(agent_id: ids).group(:agent_id).maximum(:created_at)
      eval_runs = latest_evaluation_runs(ids)

      trace_stats = telemetry_stats(ids, window_start)
      trace_last = unclaimed_traces(ids, nil).group(:agent_id).maximum(:timestamp)
      costs = estimated_costs(ids, windowed, window_start)

      ids.index_with do |id|
        runs = run_counts[id].to_i
        stats = trace_stats[id] || {}
        traced = stats[:count].to_i
        total = runs + traced
        succeeded = completed_counts[id].to_i + stats[:ok].to_i
        eval_run = eval_runs[id]

        {
          window_days: (WINDOW / 1.day).to_i,
          runs: total,
          # Which sources contributed, so the UI can say where numbers came from.
          run_sources: run_sources(runs, traced),
          success_rate: total.positive? ? (succeeded * 100.0 / total).round(1) : nil,
          avg_duration_ms: blended_duration(avg_durations[id], runs, stats[:avg_duration], traced),
          tokens: token_sums[id].to_i + stats[:tokens].to_i,
          cost: costs[id],
          eval_score: eval_run&.average_score,
          eval_samples_passed: eval_run&.samples_passed,
          eval_samples_evaluated: eval_run&.samples_evaluated,
          last_run_at: [ last_runs[id], trace_last[id] ].compact.max&.iso8601
        }
      end
    end

    # Count, success, latency and tokens for SDK-reported executions, in one
    # grouped query. The success count uses SUM(CASE ...) rather than the
    # tidier COUNT(*) FILTER so the same statement runs on SQLite and MySQL.
    def self.telemetry_stats(agent_ids, window_start)
      traces = ActionAgent.trace_model.table_name

      rows = unclaimed_traces(agent_ids, window_start)
        .group("#{traces}.agent_id")
        .pluck(
          Arel.sql("#{traces}.agent_id"),
          Arel.sql("COUNT(*)"),
          Arel.sql("SUM(CASE WHEN #{traces}.status <> 'ERROR' THEN 1 ELSE 0 END)"),
          Arel.sql("AVG(#{traces}.total_duration_ms)"),
          Arel.sql(
            "SUM(COALESCE(total_input_tokens, 0) + COALESCE(total_output_tokens, 0) + " \
            "COALESCE(total_thinking_tokens, 0))"
          )
        )

      rows.to_h do |agent_id, count, ok, avg_duration, tokens|
        [ agent_id, { count: count, ok: ok.to_i, avg_duration: avg_duration, tokens: tokens } ]
      end
    end
    private_class_method :telemetry_stats

    # Estimated USD spend per agent over the window, across both sources.
    # Rates are per model (ModelPricing), so the token columns are plucked
    # alongside the model rather than summed in SQL — two queries, no payload
    # loading: the trace's model lives in the spans jsonb and is extracted
    # there, the run's in output_metadata.
    def self.estimated_costs(agent_ids, windowed_runs, window_start)
      costs = Hash.new(0.0)
      priced = Set.new

      run_models(windowed_runs).each do |agent_id, model, input, output|
        cost = ModelPricing.estimate(model: model, input_tokens: input, output_tokens: output)
        next unless cost

        costs[agent_id] += cost
        priced << agent_id
      end

      trace_models(unclaimed_traces(agent_ids, window_start)).each do |agent_id, model, input, output|
        cost = ModelPricing.estimate(model: model, input_tokens: input, output_tokens: output)
        next unless cost

        costs[agent_id] += cost
        priced << agent_id
      end

      # nil, not 0.0, for agents with nothing to price — the card shows "—"
      # rather than claiming a real $0.00 spend.
      agent_ids.index_with { |id| priced.include?(id) ? costs[id].round(4) : nil }
    end
    private_class_method :estimated_costs

    # [agent_id, model, input_tokens, output_tokens] per run. The model
    # lives in the output_metadata JSON, which only PostgreSQL can reach
    # from SQL; elsewhere the column is read back in Ruby.
    def self.run_models(runs)
      if AgentRun.postgres?
        runs.pluck(:agent_id, Arel.sql("output_metadata ->> 'model'"), :input_tokens, :output_tokens)
      else
        runs.pluck(:agent_id, :output_metadata, :input_tokens, :output_tokens).map do |agent_id, metadata, input, output|
          [ agent_id, metadata.is_a?(Hash) ? metadata["model"] : nil, input, output ]
        end
      end
    end
    private_class_method :run_models

    # The same, for reported traces: the model is on the first llm span.
    def self.trace_models(traces)
      table = ActionAgent.trace_model.table_name

      ActionAgent.trace_model.pluck_with_llm_model(
        traces, Arel.sql("#{table}.agent_id"), :total_input_tokens, :total_output_tokens
      ).map { |model, agent_id, input, output| [ agent_id, model, input, output ] }
    end
    private_class_method :trace_models

    # Traces attributed to these agents that no AgentRun already accounts for.
    # window_start nil scans all time (used for "last activity"). Shared with
    # AgentExecutions so the cards, the list and the counts never disagree.
    def self.unclaimed_traces(agent_ids, window_start)
      AgentExecutions.unclaimed_traces(agent_ids, since: window_start)
    end
    private_class_method :unclaimed_traces

    def self.run_sources(runs, traced)
      sources = []
      sources << "platform" if runs.positive?
      sources << "telemetry" if traced.positive?
      sources
    end
    private_class_method :run_sources

    # Duration averages weight by how many executions each source contributed,
    # so a blend of platform runs and traces isn't skewed by the smaller set.
    def self.blended_duration(run_avg, runs, trace_avg, traced)
      weighted = (run_avg.to_f * runs) + (trace_avg.to_f * traced)
      counted = (run_avg ? runs : 0) + (trace_avg ? traced : 0)
      return nil if counted.zero?

      (weighted / counted).round
    end
    private_class_method :blended_duration

    # Latest complete evaluation run per agent. DISTINCT ON would do this in
    # one pass on PostgreSQL, but it has no portable equivalent, so the
    # highest id per agent (runs are only ever appended) is selected first
    # and those rows fetched by id.
    def self.latest_evaluation_runs(agent_ids)
      evaluations = Evaluation.table_name
      runs = EvaluationRun.table_name

      newest = EvaluationRun.complete.joins(:evaluation)
        .where(evaluations => { agent_id: agent_ids })
        .group("#{evaluations}.agent_id")
        .pluck(Arel.sql("#{evaluations}.agent_id"), Arel.sql("MAX(#{runs}.id)"))

      by_run_id = newest.to_h { |agent_id, run_id| [ run_id, agent_id ] }
      EvaluationRun.where(id: by_run_id.keys).index_by { |run| by_run_id[run.id] }
    end
    private_class_method :latest_evaluation_runs
  end
end
