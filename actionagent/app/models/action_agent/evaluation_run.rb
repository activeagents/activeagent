# frozen_string_literal: true

module ActionAgent
  # One execution of an Evaluation over a sample of the agent's generations.
  # scores: { criterion_key => { "score", "min", "max", "passed", "total" } },
  # except on a comparison run, where each criterion is a cohort map of
  # model => stats and "_"-prefixed metadata keys sit alongside the criteria.
  # See #average_score, which is what has to tolerate both shapes.
  class EvaluationRun < ApplicationRecord
    belongs_to :evaluation
    has_many :scenario_results, class_name: "EvaluationScenarioResult", dependent: :destroy

    enum :status, { pending: 0, running: 1, complete: 2, failed: 3 }

    scope :recent, -> { order(created_at: :desc) }

    # Which scenarios and models a scenario run covered; empty for a
    # generation-sampling run.
    def selection
      value = super
      value.is_a?(Hash) ? value : {}
    end

    # The candidate models a scenario run compared, in the order they were
    # requested; empty for a generation-sampling run.
    def models
      Array(scores&.dig("_models")&.keys)
    end

    # The label ActiveAgent::Evals::Report gives a verdict it ranked by pass
    # rate itself, for a comparison no judge was available to rule on. Read
    # from the framework rather than restated: the report reads it back when
    # it names the judge, so the two have to agree on the string.
    PASS_RATE_JUDGE = ActiveAgent::Evals::Report::PASS_RATE_JUDGE

    # The verdict a comparison run recorded — the judge's pick and rationale
    # when a judge wrote it, the framework's pass-rate ranking otherwise —
    # as `{ "winner", "rationale", "judge" }`; nil for a single-model or
    # generation-sampling run.
    def recorded_verdict
      verdict = scores&.dig("_verdict")
      verdict.to_h.stringify_keys.presence if verdict.is_a?(Hash)
    end

    # How the report names the judge, the way the suite panel does: the
    # judge the recorded verdict names — unless that is only the pass-rate
    # ranking — else the evaluation's judge model. nil when neither is set,
    # which the report reads as "rules".
    def judge_label
      recorded = recorded_verdict&.dig("judge").to_s
      return recorded if recorded.present? && recorded != PASS_RATE_JUDGE

      evaluation.judge_model.presence
    end

    # scores is not uniformly { criterion => stats }: a comparison run also
    # records "_"-prefixed metadata (EvaluationRunnerService writes
    # "_missing_models" as an Array and "_verdict"), and each of its criteria
    # is a cohort map of model => stats rather than a single stats hash.
    # Only real criterion scores are averaged; anything else is ignored
    # rather than raising and taking the whole Evaluations page down.
    def average_score
      values = (scores || {}).reject { |key, _| key.to_s.start_with?("_") }.filter_map do |_key, value|
        criterion_score(value) if value.is_a?(Hash)
      end
      return nil if values.empty?

      (values.sum.to_f / values.size).round(3)
    end

    # Aggregate usage over the run's scenario results, for display after a
    # run: estimated cost, token totals, summed model time, and the run's
    # wall-clock runtime. Returns nil for a generation-sampling run, which
    # replays nothing itself.
    def usage
      totals = scenario_results.pick(
        Arel.sql("COUNT(*)"), Arel.sql("SUM(cost)"), Arel.sql("SUM(input_tokens)"),
        Arel.sql("SUM(output_tokens)"), Arel.sql("SUM(duration_ms)")
      )
      replays = totals&.first.to_i
      return nil if replays.zero?

      {
        replays: replays,
        cost: totals[1]&.to_f,
        input_tokens: totals[2].to_i,
        output_tokens: totals[3].to_i,
        model_time_ms: totals[4].to_i,
        runtime_ms: completed_at.present? ? ((completed_at - created_at) * 1000).round : nil
      }
    end

    # Route templates for the report's fix item actions, relative to the
    # dashboard mount: `%{key}` is filled in per MCP server by the report.
    # The JSON API leaves `mount` empty — the React app resolves paths
    # against the mount itself (dashboardPath) — while the standalone HTML
    # report page is served outside the app and needs the absolute path.
    def report_links(mount: "")
      base = mount.to_s.chomp("/")

      {
        "mcp" => "#{base}/mcp/%{key}",
        "tools" => "#{base}/tools",
        "instructions" => "#{base}/agents/#{evaluation.agent_id}/edit"
      }
    end

    # What to fix, from the framework's Report: one item per fault plus one
    # per instruction change the judge proposed, each naming the tools
    # involved, the MCP server that serves them and whether this run's
    # agent has it enabled (EvaluationToolResolver), and the dashboard
    # action that addresses it. Empty for a generation-sampling run.
    def fix_items(links: report_links)
      to_report(links: links).fix_items
    end

    # Rebuilds the framework's Report from this run's persisted results, so
    # the dashboard serves the same self-contained report page a CLI run
    # writes with Report#to_html. The run's recorded verdict and judge go
    # with it: the report is not to re-rank the rebuilt results by pass
    # rate and show a different judge's pick, verdict or `judged by` than
    # the suite panel does. Raises ActiveRecord::RecordNotFound via the
    # caller for a run of a generation-sampling evaluation, which has no
    # scenario results to report on.
    def to_report(links: report_links)
      rows = scenario_results.includes(:scenario).joins(:scenario)
        .order(EvaluationScenario.arel_table[:position], EvaluationScenario.arel_table[:id], :model)
      selected = selected_specs
      specs = {}
      results = rows.map do |row|
        spec = specs[[ row.provider.to_s, row.model ]] ||= selected[[ row.provider.to_s, row.model ]] || ModelSpec.new(
          label: [ row.provider.presence, row.model ].compact.join("/"), provider: row.provider.to_s, model: row.model
        )
        ActiveAgent::Evals::Result.new(
          scenario: ActiveAgent::Evals::Scenario.from_hash(row.scenario.as_json_summary),
          spec: spec,
          replay: ActiveAgent::Evals::Replay.new(
            answer: row.output, tool_calls: Array(row.tool_calls), duration_ms: row.duration_ms,
            input_tokens: row.input_tokens, output_tokens: row.output_tokens,
            cost: row.cost&.to_f, error: row.error_message
          ),
          scores: row.scores.to_h, score: row.score, status: row.status,
          diagnosis: row.diagnosis.presence
        )
      end

      ActiveAgent::Evals::Report.new(
        results: results,
        models: (selected.values & specs.values) + (specs.values - selected.values),
        metadata: {
          "evaluation" => evaluation.name,
          "agent" => evaluation.agent&.name,
          "run" => id,
          "finished" => completed_at&.iso8601
        }.compact,
        verdict: recorded_verdict,
        judge_label: judge_label,
        tool_resolver: EvaluationToolResolver.new(evaluation.agent),
        agent_name: evaluation.agent&.name,
        links: links
      )
    end

    private

    ModelSpec = ActiveAgent::Evals::ModelSpec
    private_constant :ModelSpec

    # The candidate specs the run was asked to compare, keyed by
    # [provider, model] in the order requested. ScenarioEvaluationRunner
    # persists each ModelSpec#to_h in `selection`, and it is that label —
    # the string the user typed, e.g. "gpt-5-mini" — that keys the run's
    # `_models` and names the verdict's winner, so the rebuilt report has
    # to reuse it rather than relabel every model provider/model.
    def selected_specs
      Array(selection["models"]).filter_map do |entry|
        next unless entry.is_a?(Hash)

        entry = entry.stringify_keys
        next if entry["model"].blank?

        ModelSpec.new(label: entry["label"].presence || entry["model"], provider: entry["provider"].to_s, model: entry["model"])
      end.index_by { |spec| [ spec.provider, spec.model ] }
    end

    # A criterion is either scored directly ({ "score" => 0.8, ... }) or, on a
    # comparison run, a map of model => stats; that cohort's mean is the
    # criterion's headline score. Skipped criteria carry no score at all.
    def criterion_score(value)
      return value["score"] if value["score"].is_a?(Numeric)

      cohort = value.each_value.filter_map do |stats|
        stats["score"] if stats.is_a?(Hash) && stats["score"].is_a?(Numeric)
      end
      return nil if cohort.empty?

      cohort.sum.to_f / cohort.size
    end
  end
end
