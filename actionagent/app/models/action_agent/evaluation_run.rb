# frozen_string_literal: true

module ActionAgent
  # One execution of an Evaluation over a sample of the agent's generations.
  # scores: { criterion_key => { "score", "min", "max", "passed", "total" } },
  # except on a comparison run, where each criterion is a cohort map of
  # model => stats and "_"-prefixed metadata keys sit alongside the criteria.
  # See #average_score, which is what has to tolerate both shapes.
  class EvaluationRun < ApplicationRecord
    belongs_to :evaluation
    # The version of the evaluated agent this run scored, so a pass rate is
    # a statement about a release rather than about "the agent". A run the
    # engine executes scored the agent as it is now; an imported run scored
    # the publishing application's code, which only its report can name
    # (EvaluationReportImport sets the version from `report.release`), so
    # a release-less import stays unrecorded rather than claiming the
    # dashboard's latest version.
    belongs_to :agent_version, optional: true
    before_create { self.agent_version_id ||= evaluation&.agent&.latest_version&.id unless imported? }
    # A run started on an archived evaluation brings it back: archiving says
    # "no longer maintained", which a new run contradicts.
    after_create { evaluation.unarchive! if evaluation&.archived? }
    has_many :scenario_results, class_name: "EvaluationScenarioResult", dependent: :destroy

    enum :status, { pending: 0, running: 1, complete: 2, failed: 3 }

    scope :recent, -> { order(created_at: :desc) }

    # Whether this run was published by an application that ran it itself
    # (EvaluationReportImport) rather than executed here.
    def imported?
      external_run_id.present?
    end

    # Which scenarios and models a scenario run covered; empty for a
    # generation-sampling run.
    def selection
      value = super
      value.is_a?(Hash) ? value : {}
    end

    # The checkout sandbox a scenario run replayed against
    # (ScenarioEvaluationRunner records it), as { "session_id", "server_key",
    # "repository", "repository_ref" }; nil for a run against the agent's own
    # servers only.
    def sandbox
      value = selection["sandbox"]
      return value if value.is_a?(Hash)

      # Still pending: run_later! recorded only what was asked for.
      id = selection["sandbox_id"]
      { "session_id" => id } if id.is_a?(String) && id.present?
    end

    # The candidate models a scenario run compared, in the order they were
    # requested; empty for a generation-sampling run.
    def models
      Array(scores&.dig("_models")&.keys)
    end

    def report_metadata
      value = scores&.dig("_metadata")
      value.is_a?(Hash) ? value : {}
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
      return scores["_judge_label"] if scores&.key?("_judge_label")

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

    # The judge's own spend on this run as the engine's meter recorded it —
    # calls, tokens, estimated cost and how many calls served each purpose
    # — or nil for a run the engine did not judge (a rules-only run, or an
    # imported one, whose judge the application ran).
    def judge_usage_meter
      value = scores&.dig("_judge_usage")
      value.is_a?(Hash) ? value : nil
    end

    # The judge's spend on this run from whatever recorded it: the meter,
    # the publishing application's figures, or the judge traces priced
    # (EvaluationRunCost). nil for a run no judge was asked about.
    def judge_usage
      cost_breakdown.judge_usage
    end

    # Every cost figure of this run — per result, per scenario, per model
    # and in total — worked out once (EvaluationRunCost). A controller that
    # lists runs preloads it (EvaluationRunCost.preload) and hands it in.
    def cost_breakdown
      @cost_breakdown ||= EvaluationRunCost.for(self)
    end

    attr_writer :cost_breakdown

    # Forgets the breakdown, so a run whose results just changed is priced again.
    def reload(*)
      @cost_breakdown = nil
      super
    end

    # Per-model summaries of a generation-sampling run's cohorts, keyed by
    # model; empty for a scenario run or a run recorded before they were.
    def cohorts
      value = scores&.dig("_cohorts")
      value.is_a?(Hash) ? value : {}
    end

    # Per-model summaries of a scenario run, keyed by label, as the runner
    # recorded them under "_models", each with its cost as it stands now:
    # the effective "cost" over its results (reported, else estimated), the
    # "priced", "reported" and "estimated" counts behind it, and the
    # judge's "judge_cost" and "judge_calls" on them (EvaluationRunCost). A
    # recorded summary no result maps to is served as recorded. Empty for a
    # generation-sampling run.
    def model_summaries
      summaries = scores&.dig("_models")
      return {} unless summaries.is_a?(Hash)

      costed = cost_breakdown.by_label(summaries.keys)
      summaries.to_h do |label, stats|
        next [ label, stats ] unless stats.is_a?(Hash) && costed.key?(label)

        [ label, stats.merge(costed[label]) ]
      end
    end

    # What the run spent, for display after it: the agent's side and the
    # judge's, kept apart because they answer different questions.
    #
    # The agent's side is the operating figure — what the interactions cost
    # to serve. For a scenario run that is its replays' cost, tokens and
    # summed model time (`replays` of them); for a generation-sampling run
    # it is the sampled generations' (`samples`), which were served before
    # the run and cost it nothing.
    #
    # Every interaction with tokens is priced (EvaluationRunCost): `cost`
    # sums the reported costs and, where none was reported, the estimates
    # from tokens × model rates. `priced` and `unpriced` count the
    # interactions either way, `reported` and `estimated` say how the priced
    # ones were priced, and `cost_basis` sums that up as "reported",
    # "estimated" or "mixed". `per_interaction` is the cost per priced
    # interaction, the number a per-conversation budget is set against.
    #
    # `judge` is the evaluation's own overhead: the judge model's calls
    # (scoring, recommending, the verdict, authoring KPIs), which run
    # agent-to-agent and offline — from the engine's meter, the publishing
    # application's figures or the judge traces, with `source` naming which
    # and `run` the calls no result owns. `total` is the two sides together.
    #
    # Returns nil for a run that recorded nothing on either side.
    def usage
      cost_breakdown.usage
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
    #
    # With `estimate` (the default) each replay carries its effective cost
    # and how it was priced (EvaluationRunCost), and the report is told the
    # judge's run-level spend, so the page shows every cost the dashboard
    # does. `estimate: false` rebuilds the report from what was recorded
    # alone — the import summarizes a published run that way, so the
    # summaries it stores stay the application's own figures.
    #
    # The engine runs against every activeagent since 1.4, so the report
    # kwargs that arrived later are passed only when Report.new takes them.
    def to_report(links: report_links, estimate: true)
      rows = scenario_results.includes(:scenario).sort_by do |row|
        [ row.evaluated_scenario["position"].to_i, row.evaluation_scenario_id, row.model ]
      end
      breakdown = cost_breakdown if estimate
      selected = selected_specs
      specs = {}
      results = rows.map do |row|
        spec = specs[[ row.provider.to_s, row.model ]] ||= selected[[ row.provider.to_s, row.model ]] || ModelSpec.new(
          label: [ row.provider.presence, row.model ].compact.join("/"), provider: row.provider.to_s, model: row.model
        )
        ActiveAgent::Evals::Result.new(
          scenario: ActiveAgent::Evals::Scenario.from_hash(row.evaluated_scenario),
          spec: spec,
          replay: ActiveAgent::Evals::Replay.new(
            answer: row.output, tool_calls: Array(row.tool_calls), duration_ms: row.duration_ms,
            input_tokens: row.input_tokens, output_tokens: row.output_tokens,
            cost: breakdown ? breakdown.result(row)["cost"] : row.cost&.to_f, error: row.error_message,
            metadata: replay_metadata_for(row, breakdown)
          ),
          scores: row.scores.to_h, score: row.score, status: row.status,
          diagnosis: row.evaluation_diagnosis.presence
        )
      end

      kwargs = {
        results: results,
        models: (selected.values & specs.values) + (specs.values - selected.values),
        metadata: {
          "evaluation" => evaluation.name,
          "agent" => evaluation.agent&.name,
          "run" => id,
          "finished" => completed_at&.iso8601,
          "sandbox" => sandbox_label
        }.compact.merge(report_metadata),
        verdict: recorded_verdict,
        judge_label: judge_label,
        tool_resolver: EvaluationToolResolver.new(evaluation.agent),
        agent_name: evaluation.agent&.name,
        links: links
      }
      kwargs[:judge_usage] = breakdown.judge_usage_run if breakdown && self.class.report_accepts?(:judge_usage)
      kwargs[:release] = release_summary if release_summary && self.class.report_accepts?(:release)
      self.class.report_class.new(**kwargs)
    end

    # The framework's Report, as installed.
    def self.report_class
      ActiveAgent::Evals::Report
    end

    # Whether the installed framework's Report.new declares +keyword+.
    def self.report_accepts?(keyword)
      report_class.instance_method(:initialize).parameters.any? { |type, name| name == keyword && %i[key keyreq].include?(type) }
    end

    # The release this run scored, as the report names it — `{ "digest",
    # "revision", "label" }` — or nil for a run pinned to a dashboard edit
    # or to no version.
    def release_summary
      version = agent_version
      return nil unless version&.release?

      { "digest" => version.release_digest, "revision" => version.revision, "label" => "v#{version.version_number}" }.compact
    end

    # The agent version this run scored, for the run's JSON: `{ id, number,
    # release_digest, revision, release }`, or nil when none was recorded.
    def agent_version_summary
      version = agent_version
      return nil unless version

      { id: version.id, number: version.version_number, release_digest: version.release_digest,
        revision: version.revision, release: version.release? }
    end

    private

    ModelSpec = ActiveAgent::Evals::ModelSpec
    private_constant :ModelSpec

    # The replay metadata the rebuilt report reads a result's costs from:
    # what the result recorded, the judge usage the application reported
    # for it, and — when estimating — how its cost was priced.
    def replay_metadata_for(row, breakdown)
      metadata = row.replay_metadata.dup
      reported_judge = row.diagnosis.is_a?(Hash) ? row.diagnosis["_judge_usage"] : nil
      metadata["judge_usage"] = reported_judge if reported_judge.is_a?(Hash)
      return metadata unless breakdown

      entry = breakdown.result(row)
      metadata["cost_source"] = entry["cost_source"]
      metadata["cost_rate"] = entry["cost_rate"] if entry["cost_rate"]
      metadata["judge_usage"] = entry["judge_usage"] if entry["judge_usage"]
      metadata
    end

    # How the report's header names the sandbox: its checkout and session.
    def sandbox_label
      return nil unless sandbox

      checkout = [ sandbox["repository"], sandbox["repository_ref"] ].compact_blank.join("@")
      [ checkout.presence, "sandbox #{sandbox["session_id"].to_s.first(8)}" ].compact.join(" · ")
    end

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
