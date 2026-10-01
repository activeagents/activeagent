# frozen_string_literal: true

module ActionAgent
  # What an evaluation run cost, worked out from everything the run and its
  # results recorded, so that no cost shows blank where tokens exist.
  #
  # Each scenario result is priced down a chain, the first link that applies
  # winning, and says which link it was (`cost_source`):
  #
  #   reported   — a cost the publishing application sent with the result
  #   estimated  — the cost the engine stored when it ran the replay itself
  #                (tokens × the model's rate at the time), else the
  #                result's tokens × the model's rate now, else the tokens
  #                of the telemetry trace the result links to × that rate,
  #                else the prompt and answer at ~4 characters a token — a
  #                lower bound, for a result that recorded no tokens at all
  #   no_usage   — both token counts recorded as zero: nothing was
  #                generated, so the result cost $0.00 (an errored replay)
  #   unpriced   — no tokens, no trace and no text: nothing to price from
  #
  # An estimate carries its rate (`cost_rate`: $ per million tokens, where
  # it came from, and the tokens it was applied to), so a figure can show
  # its working. A trace's thinking tokens are already inside its output
  # tokens and are never priced again.
  #
  # The judge's spend is kept apart from the agent's and found down its own
  # chain: the engine's own meter (`scores._judge_usage`), else what the
  # application reported per result (`diagnosis._judge_usage`) and for the
  # run (`scores._judge_usage_run`), else the judge traces the results and
  # the run link to, priced from their input and output tokens. Traces are
  # read within the run's tenant: the account its report was published
  # under, or the agent owner's account.
  #
  # Nothing here writes. A finished run's figures are cached in Rails.cache
  # under the run, its updated_at and the pricing tables in force, so a
  # page of runs prices its traces once; a run still landing results is
  # worked out fresh each time. `preload` prices several runs with one
  # query per table.
  class EvaluationRunCost
    CACHE_VERSION = 2
    CACHE_TTL = 7.days
    # The approximation the context meter applies to text it sizes itself.
    CHARS_PER_TOKEN = 4
    SOURCES = %w[reported estimated no_usage unpriced].freeze
    # Judge calls no result owns: the verdict across cohorts and, for a
    # judge_defined evaluation, authoring the criteria.
    RUN_LEVEL_KINDS = %w[verdict define].freeze

    attr_reader :run

    # The breakdown for one run, from the cache when it is finished and
    # cached, else computed.
    def self.for(run)
      new(run).tap(&:data)
    end

    # { run.id => EvaluationRunCost } for every run in +runs+, loading the
    # uncached runs' results and traces in one query each.
    def self.preload(runs)
      runs = Array(runs).compact.uniq(&:id)
      return {} if runs.empty?

      breakdowns = runs.index_with { |run| new(run) }
      pending = breakdowns.values.reject(&:cached?)
      rows = EvaluationScenarioResult.where(evaluation_run_id: pending.map { |breakdown| breakdown.run.id })
        .includes(:scenario).group_by(&:evaluation_run_id)
      pending.each { |breakdown| breakdown.rows = rows.fetch(breakdown.run.id, []) }
      TraceReader.preload(pending)
      pending.each(&:data)
      breakdowns.transform_keys(&:id)
    end

    def initialize(run)
      @run = run
    end

    # The results' rows, loaded once; `preload` hands them in.
    attr_writer :rows

    def rows
      @rows ||= run.scenario_results.includes(:scenario).to_a
    end

    def cached?
      return false unless cacheable?

      @data ||= Rails.cache.read(cache_key)
      @data.present?
    end

    # Every figure, as one serializable hash:
    #   { "results" => { id => entry }, "judge" => usage | nil, "usage" => ..., "costs" => ..., "by_label" => ... }
    def data
      return @data if @data

      @data = cacheable? ? Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute } : compute
    end

    # The result's figures: `{ "cost", "reported_cost", "cost_source",
    # "cost_rate", "judge_usage" }`, with `cost` the effective one. A
    # result this run does not hold reads as unpriced.
    def result(result)
      data["results"][result.id.to_s] || unpriced_entry
    end

    # The run's usage, the agent's side and the judge's apart, or nil when
    # the run recorded nothing on either side (see EvaluationRun#usage).
    def usage
      data["usage"]&.transform_keys(&:to_sym)
    end

    # The judge's spend on the run, or nil when no judge was asked.
    def judge_usage
      data["judge"]
    end

    # The judge's calls no result owns, in the shape Report.new(judge_usage:)
    # takes. The engine's meter knows no result's share, so a metered run
    # hands the report the whole meter: from the report's side, none of it
    # is any result's.
    def judge_usage_run
      judge = judge_usage
      return nil unless judge
      return judge.except("run", "estimated") if judge["source"] == "meter"
      return nil unless judge["run"]

      judge["run"].merge("model" => judge["model"], "source" => judge["source"]).compact
    end

    # Costs per scenario and for the run (see Api::EvaluationsController#show_run).
    def costs
      data["costs"]
    end

    # Per model label: the effective cost and the counts behind it, to merge
    # into the run's recorded `_models` summaries.
    def by_label(labels)
      data["by_label"].select { |label, _| labels.include?(label) }
    end

    # The trace ids this run refers to: each result's own replay trace and
    # judge traces, and the run's judge traces (the verdict's). TraceReader
    # reads them and hands the traces back through `traces=`.
    def trace_ids
      ids = rows.flat_map { |row| [ row.replay_metadata["trace_id"], *Array(row.replay_metadata["judge_trace_ids"]) ] }
      ids.concat(Array(run.report_metadata["judge_trace_ids"]))
      ids.filter_map { |id| id.to_s.presence }.uniq
    end

    attr_writer :traces

    private

    def cacheable?
      run.persisted? && run.complete? && run.updated_at.present?
    end

    def cache_key
      [ "action_agent", "evaluation_run_cost", CACHE_VERSION, run.id, run.updated_at.utc.strftime("%Y%m%d%H%M%S%6N"), ModelPricing.fingerprint ]
    end

    def imported?
      run.external_run_id.present?
    end

    def unpriced_entry
      { "cost" => nil, "reported_cost" => nil, "cost_source" => "unpriced", "cost_rate" => nil, "judge_usage" => nil }
    end

    # --- computation ---------------------------------------------------------

    def compute
      traces = @traces || TraceReader.new(self).read
      entries = rows.to_h { |row| [ row.id.to_s, result_entry(row, traces).merge("judge_usage" => result_judge(row, traces)) ] }
      judge = run_judge_usage(entries, traces)
      {
        "results" => entries,
        "judge" => judge,
        "usage" => usage_for(entries, judge),
        "costs" => costs_for(entries, judge),
        "by_label" => by_label_for(entries)
      }
    end

    # The agent's cost of one result, down the chain in the class comment.
    def result_entry(row, traces)
      if !row.cost.nil? && imported?
        return { "cost" => row.cost.to_f, "reported_cost" => row.cost.to_f, "cost_source" => "reported", "cost_rate" => nil }
      end

      if !row.cost.nil?
        rate = ModelPricing.rate_detail(row.model, provider: row.provider)
        return estimated(row.cost.to_f, rate, "tokens", row.input_tokens, row.output_tokens)
      end

      input = row.input_tokens
      output = row.output_tokens
      return { "cost" => 0.0, "reported_cost" => nil, "cost_source" => "no_usage", "cost_rate" => nil } if input == 0 && output == 0

      if input.to_i.positive? || output.to_i.positive?
        return priced("tokens", row.model, row.provider, input, output)
      end

      trace = traces[row.replay_metadata["trace_id"].to_s]
      if trace
        return { "cost" => 0.0, "reported_cost" => nil, "cost_source" => "no_usage", "cost_rate" => nil } if trace.input_tokens.zero? && trace.output_tokens.zero?

        return priced("trace", trace.model.presence || row.model, trace.provider.presence || row.provider, trace.input_tokens, trace.output_tokens)
      end

      prompt_chars = row.evaluated_scenario["prompt"].to_s.length
      answer_chars = row.output.to_s.length
      if prompt_chars.positive? || answer_chars.positive?
        return priced("chars", row.model, row.provider, prompt_chars / CHARS_PER_TOKEN, answer_chars / CHARS_PER_TOKEN)
      end

      unpriced_entry.except("judge_usage")
    end

    def priced(basis, model, provider, input_tokens, output_tokens)
      detail = ModelPricing.estimate_detailed(model: model, provider: provider, input_tokens: input_tokens, output_tokens: output_tokens)
      return { "cost" => 0.0, "reported_cost" => nil, "cost_source" => "no_usage", "cost_rate" => nil } unless detail

      rate = { input: detail[:input_rate], output: detail[:output_rate], source: detail[:source] }
      estimated(detail[:cost], rate, basis, input_tokens, output_tokens)
    end

    def estimated(cost, rate, basis, input_tokens, output_tokens)
      {
        "cost" => cost.to_f.round(6),
        "reported_cost" => nil,
        "cost_source" => "estimated",
        "cost_rate" => {
          "input" => rate[:input], "output" => rate[:output], "source" => rate[:source],
          "basis" => basis, "input_tokens" => input_tokens.to_i, "output_tokens" => output_tokens.to_i
        }
      }
    end

    # --- judge -----------------------------------------------------------------

    # What the judge spent on one result: the application's own figures when
    # it reported them, else the result's judge traces priced; nil when the
    # engine metered the run (the meter is per run, not per result) or
    # nothing links a judge call to the result.
    def result_judge(row, traces)
      return nil if run.judge_usage_meter

      reported = row.diagnosis.is_a?(Hash) ? row.diagnosis["_judge_usage"] : nil
      return normalize_reported_judge(reported) if reported.is_a?(Hash)

      judge_traces = Array(row.replay_metadata["judge_trace_ids"]).filter_map { |id| traces[id.to_s] }
      traces_usage(judge_traces)
    end

    # The run's judge usage: `{ "calls", "input_tokens", "output_tokens",
    # "cost", "model", "by_kind", "source", "estimated", "run" => { "calls",
    # "cost", "by_kind" } }`, the engine meter first, then what the
    # application reported, then the judge traces.
    def run_judge_usage(entries, traces)
      if (meter = run.judge_usage_meter)
        return metered_judge(meter)
      end

      parts = entries.values.filter_map { |entry| entry["judge_usage"] }
      reported_run = run.scores.is_a?(Hash) ? run.scores["_judge_usage_run"] : nil
      run_part = normalize_reported_judge(reported_run) if reported_run.is_a?(Hash)
      if parts.any? { |part| part["source"] == "reported" } || run_part
        return sum_judge(parts + [ run_part ].compact, run_part, "reported")
      end

      result_ids = rows.flat_map { |row| Array(row.replay_metadata["judge_trace_ids"]) }.map(&:to_s)
      run_traces = Array(run.report_metadata["judge_trace_ids"]).map(&:to_s).uniq.reject { |id| result_ids.include?(id) }.filter_map { |id| traces[id] }
      run_part = traces_usage(run_traces)
      return nil if parts.empty? && run_part.nil?

      sum_judge(parts + [ run_part ].compact, run_part, "traces")
    end

    # The engine's meter knows the run's total and what each call was for,
    # not which result each call served: the run-level part is the calls
    # of a run-level kind, their cost unknown.
    def metered_judge(meter)
      by_kind = (meter["by_kind"] || {}).to_h.transform_keys(&:to_s)
      run_kinds = by_kind.select { |kind, _| RUN_LEVEL_KINDS.include?(kind) }
      {
        "calls" => meter["calls"].to_i,
        "input_tokens" => meter["input_tokens"].to_i,
        "output_tokens" => meter["output_tokens"].to_i,
        "cost" => meter["cost"]&.to_f&.round(6),
        "model" => meter["model"].presence,
        "by_kind" => by_kind,
        "source" => "meter",
        "estimated" => true,
        "run" => { "calls" => run_kinds.values.sum(&:to_i), "cost" => nil, "by_kind" => run_kinds }
      }
    end

    # A usage the application reported — per result, or for the run —
    # bounded to the keys the dashboard reads. A usage with tokens but no
    # cost is priced at its model's rate and says so.
    def normalize_reported_judge(usage)
      usage = usage.to_h.transform_keys(&:to_s)
      input = usage["input_tokens"].to_i
      output = usage["output_tokens"].to_i
      model = usage["model"].presence
      cost = usage["cost"].is_a?(Numeric) ? usage["cost"].to_f : nil
      estimated = false
      if cost.nil? && (input.positive? || output.positive?)
        cost = ModelPricing.estimate(model: model, input_tokens: input, output_tokens: output)
        estimated = true
      end
      by_kind = usage["by_kind"].is_a?(Hash) ? usage["by_kind"].to_h { |kind, count| [ kind.to_s, count.to_i ] } : {}
      {
        "calls" => [ usage["calls"].to_i, 1 ].max,
        "input_tokens" => input,
        "output_tokens" => output,
        "cost" => cost&.round(6),
        "model" => model,
        "by_kind" => by_kind,
        "source" => "reported",
        "estimated" => estimated
      }
    end

    # Judge traces priced from their input and output tokens — never their
    # thinking tokens, which the output count already holds. nil without a trace.
    def traces_usage(judge_traces)
      return nil if judge_traces.empty?

      costs = judge_traces.filter_map do |trace|
        ModelPricing.estimate(model: trace.model, provider: trace.provider, input_tokens: trace.input_tokens, output_tokens: trace.output_tokens)
      end
      {
        "calls" => judge_traces.size,
        "input_tokens" => judge_traces.sum(&:input_tokens),
        "output_tokens" => judge_traces.sum(&:output_tokens),
        "cost" => costs.any? ? costs.sum.round(6) : 0.0,
        "model" => judge_traces.filter_map { |trace| trace.model.presence }.first,
        "by_kind" => judge_traces.filter_map { |trace| trace.action.presence }.tally,
        "source" => "traces",
        "estimated" => true
      }
    end

    def sum_judge(parts, run_part, source)
      costs = parts.filter_map { |part| part["cost"] }
      {
        "calls" => parts.sum { |part| part["calls"].to_i },
        "input_tokens" => parts.sum { |part| part["input_tokens"].to_i },
        "output_tokens" => parts.sum { |part| part["output_tokens"].to_i },
        "cost" => costs.any? ? costs.sum.round(6) : nil,
        "model" => parts.filter_map { |part| part["model"].presence }.first,
        "by_kind" => parts.each_with_object({}) { |part, tally| (part["by_kind"] || {}).each { |kind, count| tally[kind] = tally.fetch(kind, 0) + count.to_i } },
        "source" => source,
        "estimated" => parts.any? { |part| part["estimated"] },
        "run" => run_part && { "calls" => run_part["calls"].to_i, "cost" => run_part["cost"], "by_kind" => run_part["by_kind"] || {} }
      }.compact
    end

    # --- roll-ups --------------------------------------------------------------

    # The run's usage (EvaluationRun#usage): the agent's side summed over
    # the results, the judge's beside it, and their total.
    def usage_for(entries, judge)
      runtime_ms = run.completed_at.present? && run.created_at.present? ? ((run.completed_at - run.created_at) * 1000).round : nil
      if rows.any?
        priced = entries.values.count { |entry| entry["cost"] }
        cost = entries.values.filter_map { |entry| entry["cost"] }.sum.round(6)
        reported = entries.values.count { |entry| entry["cost_source"] == "reported" }
        estimated = entries.values.count { |entry| entry["cost_source"] == "estimated" }
        agent_cost = priced.positive? ? cost : nil
        {
          "replays" => rows.size,
          "priced" => priced,
          "unpriced" => rows.size - priced,
          "reported" => reported,
          "estimated" => estimated,
          "cost" => agent_cost,
          "per_interaction" => agent_cost && priced.positive? ? (agent_cost / priced).round(6) : nil,
          "input_tokens" => rows.sum { |row| row.input_tokens.to_i },
          "output_tokens" => rows.sum { |row| row.output_tokens.to_i },
          "model_time_ms" => rows.sum { |row| row.duration_ms.to_i },
          "runtime_ms" => runtime_ms,
          "cost_basis" => (cost_basis(reported, estimated) if priced.positive?),
          "judge" => judge,
          "total" => total_of(agent_cost, judge&.dig("cost"))
        }.compact
      elsif run.cohorts.any?
        sampling_usage(judge, runtime_ms)
      elsif judge
        { "runtime_ms" => runtime_ms, "judge" => judge, "total" => judge["cost"] }.compact
      end
    end

    # A generation-sampling run's side: what the sampled generations cost to
    # serve, as the runner recorded per cohort — always an estimate from
    # tokens. A cohort recorded before `priced` counts all its samples when
    # it has a cost and none when it has not.
    def sampling_usage(judge, runtime_ms)
      cohorts = run.cohorts.values
      samples = cohorts.sum { |cohort| cohort["samples"].to_i }
      priced = cohorts.sum { |cohort| cohort.key?("priced") ? cohort["priced"].to_i : (cohort["cost"].nil? ? 0 : cohort["samples"].to_i) }
      costs = cohorts.filter_map { |cohort| cohort["cost"] }
      cost = costs.any? ? costs.sum.to_f.round(6) : nil
      {
        "samples" => samples,
        "priced" => priced,
        "unpriced" => samples - priced,
        "reported" => 0,
        "estimated" => priced,
        "cost" => cost,
        "per_interaction" => cost && priced.positive? ? (cost / priced).round(6) : nil,
        "input_tokens" => cohorts.sum { |cohort| cohort["input_tokens"].to_i },
        "output_tokens" => cohorts.sum { |cohort| cohort["output_tokens"].to_i },
        "runtime_ms" => runtime_ms,
        "cost_basis" => (cost && "estimated"),
        "judge" => judge,
        "total" => total_of(cost, judge&.dig("cost"))
      }.compact
    end

    def cost_basis(reported, estimated)
      if reported.positive? && estimated.positive? then "mixed"
      elsif estimated.positive? then "estimated"
      else "reported"
      end
    end

    def total_of(agent_cost, judge_cost)
      return nil if agent_cost.nil? && judge_cost.nil?

      (agent_cost.to_f + judge_cost.to_f).round(6)
    end

    # Per scenario key — the agent's cost summed over the models, the
    # judge's, their total, whether any part is an estimate, and the same
    # per model label — and for the run as a whole.
    def costs_for(entries, judge)
      scenarios = rows.group_by { |row| row.evaluated_scenario["key"].to_s }.to_h do |key, cohort|
        parts = cohort.map { |row| entries[row.id.to_s] }
        costs = parts.filter_map { |entry| entry["cost"] }
        judge_costs = parts.filter_map { |entry| entry.dig("judge_usage", "cost") }
        cost = costs.any? ? costs.sum.round(6) : nil
        judge_cost = judge_costs.any? ? judge_costs.sum.round(6) : nil
        [ key, {
          "cost" => cost,
          "judge_cost" => judge_cost,
          "total" => total_of(cost, judge_cost),
          "estimated" => parts.any? { |entry| entry["cost_source"] == "estimated" || entry.dig("judge_usage", "estimated") } ||
                         (costs.any? && costs.size < parts.size),
          "models" => cohort.to_h do |row|
            entry = entries[row.id.to_s]
            [ label_for(row), { "cost" => entry["cost"], "judge_cost" => entry.dig("judge_usage", "cost"), "cost_source" => entry["cost_source"] } ]
          end
        } ]
      end
      agent_costs = entries.values.filter_map { |entry| entry["cost"] }
      agent_cost = agent_costs.any? ? agent_costs.sum.round(6) : nil
      reported = entries.values.count { |entry| entry["cost_source"] == "reported" }
      estimated = entries.values.count { |entry| entry["cost_source"] == "estimated" }
      {
        "scenarios" => scenarios,
        "run" => {
          "agent_cost" => agent_cost,
          "judge_cost" => judge&.dig("cost"),
          "total" => total_of(agent_cost, judge&.dig("cost")),
          "cost_basis" => (cost_basis(reported, estimated) if agent_cost)
        }
      }
    end

    # Per model label: `{ "cost", "priced", "reported", "estimated",
    # "judge_cost", "judge_calls" }` over that label's results.
    def by_label_for(entries)
      rows.group_by { |row| label_for(row) }.to_h do |label, cohort|
        parts = cohort.map { |row| entries[row.id.to_s] }
        costs = parts.filter_map { |entry| entry["cost"] }
        judge_costs = parts.filter_map { |entry| entry.dig("judge_usage", "cost") }
        [ label, {
          "cost" => costs.any? ? costs.sum.round(6) : nil,
          "priced" => costs.size,
          "reported" => parts.count { |entry| entry["cost_source"] == "reported" },
          "estimated" => parts.count { |entry| entry["cost_source"] == "estimated" },
          "judge_cost" => judge_costs.any? ? judge_costs.sum.round(6) : nil,
          "judge_calls" => parts.sum { |entry| entry.dig("judge_usage", "calls").to_i }
        } ]
      end
    end

    # The label a result's model runs under in the run's summaries: the one
    # the run's selection gave its provider and model, else — the way the
    # dashboard assigns results to model columns — the recorded summary
    # naming its model bare or as "provider/model", else the bare model.
    def label_for(row)
      @labels ||= {}
      @labels[[ row.provider.to_s, row.model ]] ||= begin
        selected = selected_labels[[ row.provider.to_s, row.model ]]
        recorded = run.scores.is_a?(Hash) && run.scores["_models"].is_a?(Hash) ? run.scores["_models"].keys : []
        selected || [ row.model, [ row.provider.presence, row.model ].compact.join("/") ].find { |name| recorded.include?(name) } || row.model
      end
    end

    def selected_labels
      @selected_labels ||= Array(run.selection["models"]).filter_map do |entry|
        next unless entry.is_a?(Hash)

        entry = entry.stringify_keys
        next if entry["model"].blank?

        [ [ entry["provider"].to_s, entry["model"] ], entry["label"].presence || entry["model"] ]
      end.to_h
    end

    # The traces a run's results and judge link to, read within the run's
    # tenant and reduced to what pricing needs: tokens, the llm span's
    # model and provider, and the action (a judge trace's action is the
    # kind of call it served — Correlation#judge names it).
    class TraceReader
      Trace = Struct.new(:trace_id, :input_tokens, :output_tokens, :model, :provider, :action, keyword_init: true)

      # Reads every pending breakdown's traces, one query per tenant.
      def self.preload(breakdowns)
        breakdowns.group_by { |breakdown| new(breakdown).tenant_key }.each_value do |group|
          reader = new(group.first)
          traces = reader.read(group.flat_map(&:trace_ids))
          group.each { |breakdown| breakdown.traces = traces }
        end
      end

      def initialize(breakdown)
        @breakdown = breakdown
        @run = breakdown.run
      end

      # { trace_id => Trace } for +ids+ (the breakdown's own by default).
      def read(ids = @breakdown.trace_ids)
        ids = ids.map(&:to_s).uniq
        return {} if ids.empty?

        scope = tenant_scope
        return {} if scope.nil?

        table = ActionAgent.trace_model.table_name
        rows = ActionAgent.trace_model.pluck_with_llm_model(
          scope.where(trace_id: ids),
          Arel.sql("#{table}.trace_id"), Arel.sql("#{table}.total_input_tokens"), Arel.sql("#{table}.total_output_tokens"),
          Arel.sql("#{table}.agent_action")
        )
        rows.to_h do |model, trace_id, input, output, action|
          [ trace_id.to_s, Trace.new(trace_id: trace_id.to_s, input_tokens: input.to_i, output_tokens: output.to_i,
                                     model: model, provider: provider_of(model), action: action) ]
        end
      rescue StandardError => e
        Rails.logger.warn("[ActionAgent] evaluation run #{@run.id} trace pricing failed: #{e.class}: #{e.message}")
        {}
      end

      # The tenant the run's traces belong to, as a grouping key.
      def tenant_key
        return "install" unless ActionAgent.multi_tenant?

        tenant_account&.id.to_s.presence || "none"
      end

      private

      # A gateway's model names carry the vendor; the model's own name does
      # not say which provider served it, which ModelPricing works around.
      def provider_of(model)
        head, rest = model.to_s.split("/", 2)
        rest.present? && ModelPricing::GATEWAY_PREFIXES.include?(head.downcase) ? head.downcase : nil
      end

      # The traces this run may read: every trace on a single-tenant
      # install; on a multi-tenant one, the tenant's own and nothing
      # without a tenant.
      def tenant_scope
        traces = ActionAgent.trace_model
        return traces.all unless ActionAgent.multi_tenant?

        account = tenant_account
        return nil unless account

        traces.column_names.include?("account_id") ? traces.where(account_id: account.id) : traces.for_account(account)
      end

      # The account the run's report was published under, else the one the
      # agent belongs to.
      def tenant_account
        return @tenant_account if defined?(@tenant_account)

        klass = ActionAgent.account_class.to_s.safe_constantize
        @tenant_account =
          if klass.nil?
            nil
          elsif @run.external_tenant.present?
            klass.find_by(id: @run.external_tenant)
          else
            agent = @run.evaluation&.agent
            owner = agent&.owner
            if owner.is_a?(klass) then owner
            elsif agent.respond_to?(:account_id) && agent.account_id.present? then klass.find_by(id: agent.account_id)
            end
          end
      end
    end
  end
end
