# frozen_string_literal: true

module ActionAgent
  # Used to render evaluations and their runs for the dashboard's JSON API
  # (Api::EvaluationsController) and its MCP facade (Api::MCPController), so
  # both describe an evaluation the same way.
  #
  # A run's `number` is its position in its evaluation's history, oldest = 1,
  # so a client can say "Run #3" and "vs #2".
  module EvaluationSerializer
    module_function

    # Returns the evaluation with its latest run in full and just enough of
    # the run before it to show movement ("+3 passed vs #2") without a
    # request per evaluation. The headline run — the newest complete one —
    # rides along in full as `headline_run` when a newer run is pending or
    # failed, so a page can describe the finished run while showing the
    # newer one beside it.
    def evaluation(evaluation)
      summary = summary(evaluation)
      latest, previous = recent_runs(evaluation, 2)
      headline = evaluation.standing_info.headline_run
      headline = nil if headline.nil? || headline.id == latest&.id

      summary.merge(
        latest_run: latest ? run(latest, number: summary[:run_count]) : nil,
        previous_run: previous ? run_summary(previous, number: summary[:run_count] - 1) : nil,
        headline_run: headline ? run(headline, number: run_number(evaluation, headline)) : nil
      )
    end

    # Returns the evaluation's configuration and run count, without its runs,
    # and where it stands: `headline_run_id` (its newest complete run),
    # `standing` against the agent's current version (EvaluationStanding),
    # `archived_at`, and the headline run's passes `per_model`.
    def summary(evaluation)
      standing = evaluation.standing_info
      {
        id: evaluation.id,
        name: evaluation.name,
        agent: { id: evaluation.agent.id, name: evaluation.agent.name, slug: evaluation.agent.slug },
        judge_kind: evaluation.judge_kind,
        judge_model: evaluation.judge_model,
        criteria: evaluation.criteria,
        compare_models: evaluation.compare_models,
        config: evaluation.config,
        sample_size: evaluation.sample_size,
        scenario_suite: evaluation.scenario_suite?,
        scenario_count: evaluation.scenarios.size,
        scenario_groups: evaluation.scenario_suite? ? evaluation.scenario_groups : [],
        created_at: evaluation.created_at.iso8601,
        # size reads a preloaded association and COUNTs otherwise.
        run_count: evaluation.evaluation_runs.size,
        headline_run_id: standing.headline_run&.id,
        standing: standing.standing,
        archived_at: evaluation.archived_at&.iso8601,
        per_model: standing.per_model
      }
    end

    # Returns the run summary plus its scores, selection, models, usage and
    # error.
    def run(run, number: nil)
      run_summary(run, number: number).merge(
        scores: scores(run),
        selection: run.selection,
        models: run.models,
        usage: run.usage,
        error_message: run.error_message
      )
    end

    # Returns the run's scores with each scenario model summary carrying its
    # "priced" count (EvaluationRun#model_summaries).
    def scores(run)
      summaries = run.model_summaries
      summaries.empty? ? run.scores : run.scores.merge("_models" => summaries)
    end

    # Returns the run's status and headline numbers. `sandbox` is the
    # checkout sandbox the run replayed against, if any: its session id and
    # checkout, never its token. `agent_version` is the version of the
    # agent the run scored, and `version_state` whether that is the agent's
    # current version ("current", "earlier" or "unrecorded").
    def run_summary(run, number: nil)
      {
        id: run.id,
        number: number,
        status: run.status,
        average_score: average_score(run),
        samples_evaluated: run.samples_evaluated,
        samples_passed: run.samples_passed,
        completed_at: run.completed_at&.iso8601,
        created_at: run.created_at.iso8601,
        sandbox: run.sandbox,
        agent_version: run.agent_version_summary,
        version_state: run.evaluation.standing_info.version_state(run)
      }
    end

    # Returns up to +limit+ of the evaluation's runs, newest first. Sorts the
    # preloaded association when one was loaded rather than issuing one
    # ORDER BY query per evaluation.
    def recent_runs(evaluation, limit)
      runs = evaluation.evaluation_runs
      if runs.loaded?
        runs.sort_by { |run| [ run.created_at, run.id ] }.reverse.first(limit)
      else
        runs.order(created_at: :desc, id: :desc).limit(limit).to_a
      end
    end

    # Returns the run's position in its evaluation's history, oldest = 1 —
    # counted in the preloaded association when one was loaded.
    def run_number(evaluation, run)
      runs = evaluation.evaluation_runs
      if runs.loaded?
        runs.count { |other| other.created_at < run.created_at || (other.created_at == run.created_at && other.id <= run.id) }
      else
        runs.where("created_at < ? OR (created_at = ? AND id <= ?)", run.created_at, run.created_at, run.id).count
      end
    end

    # Returns the run's fix items, or [] when they cannot be built. They are
    # derived from every persisted result's diagnosis, which older runs
    # recorded in earlier shapes, so a run they fail for still serves its
    # results. Without +links+ the item paths are relative to the mount.
    def fix_items(run, links: nil)
      links ? run.fix_items(links: links) : run.fix_items
    rescue StandardError => e
      Rails.logger.warn(
        "[ActionAgent] evaluation run #{run.id} fix_items failed: #{e.class}: #{e.message}"
      )
      []
    end

    # Returns the run's average score, or nil when its scores payload cannot
    # be averaged, so one bad run degrades its own headline number rather
    # than failing a whole listing.
    def average_score(run)
      run.average_score
    rescue StandardError => e
      Rails.logger.warn(
        "[ActionAgent] evaluation run #{run.id} average_score failed: #{e.class}: #{e.message}"
      )
      nil
    end
  end
end
