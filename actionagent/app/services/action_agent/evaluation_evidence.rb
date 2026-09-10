# frozen_string_literal: true

module ActionAgent
  # Read-only, owner-scoped facts for the dashboard assistant. Cards and links
  # come from records, not from model output. Existing runs lack repository and
  # immutable rubric provenance, so none can establish current-branch behavior.
  class EvaluationEvidence
    MAX_EVALUATIONS = 20
    MAX_CANDIDATES = 10
    MAX_SCAN_RESULTS = 200
    MAX_REPORT_RESULTS = 20
    TEXT_LIMIT = 1200
    SCORE_LIMIT = 20

    PROVENANCE_CAVEAT = "Historical evidence only: repository, tested commit, tool contract, and fixture snapshots were not recorded. This does not verify current main."
    RUBRIC_CAVEAT = "Scenario expectations and evaluation criteria are mutable; their current definitions are not a snapshot of the checks used for this result."
    REPORT_CAVEAT = "The linked report may display current scenario text and configuration. This card uses the recorded replay prompt when available."
    WEAK_CHECK_CAVEAT = "Recorded scores show only response shape or runtime checks; they do not establish answer correctness."
    CONTEXT_CAVEAT = "No matching recorded replay from this evaluation's agent supplies prompt context."
    REDACTED_ERROR = "Recorded error details withheld because they may contain credentials. Open the report for details."

    SHAPE_SCORE_KEYS = %w[response_present response_length min_length latency max_latency_ms token_budget tools_succeeded].freeze
    EXPECTATION_SCORE_KEYS = %w[expected_tools expected_content forbidden_content].freeze

    def initialize(owner:)
      @agents = ActionAgent.agents_for(owner)
    end

    def list_evaluations(agent_id: nil, query: nil, limit: MAX_EVALUATIONS)
      limit = bounded_limit(limit, MAX_EVALUATIONS)
      scope = evaluations_scope(agent_id: agent_id)
      if query.present?
        pattern = "%#{Evaluation.sanitize_sql_like(query.to_s.first(200).downcase, '!')}%"
        scope = scope.where("LOWER(#{Evaluation.quoted_table_name}.name) LIKE ? ESCAPE '!'", pattern)
      end
      rows = scope.includes(:agent).order(updated_at: :desc, id: :desc).limit(limit + 1).to_a
      evaluations = rows.first(limit)
      latest = latest_runs(evaluations.map(&:id))
      report_runs = EvaluationScenarioResult.where(evaluation_run_id: latest.values.map(&:id)).distinct.pluck(:evaluation_run_id)

      {
        cards: evaluations.map do |evaluation|
          run = latest[evaluation.id]
          {
            id: "evaluation-#{evaluation.id}", type: "evaluation", title: text(evaluation.name),
            evaluation_id: evaluation.id, agent_id: evaluation.agent_id, agent_name: text(evaluation.agent.name),
            path: "/evaluations", latest_run: run && run_summary(run, report: report_runs.include?(run.id)),
            caveats: [ PROVENANCE_CAVEAT, RUBRIC_CAVEAT ]
          }
        end,
        coverage: { returned: evaluations.size, limit: limit, truncated: rows.size > limit },
        caveats: [ PROVENANCE_CAVEAT ]
      }
    end

    def find_demo_candidates(agent_id: nil, evaluation_id: nil, limit: MAX_CANDIDATES)
      limit = bounded_limit(limit, MAX_CANDIDATES)
      evaluations = evaluations_scope(agent_id: agent_id, evaluation_id: evaluation_id)
      scope = terminal_results(evaluations)
      # Read newest attempts first, including failures. Filtering to passed
      # before deduplication would resurrect a pass superseded by a regression.
      rows = scope.preload(:agent_run, evaluation_run: { evaluation: :agent })
        .limit(MAX_SCAN_RESULTS + 1).to_a
      scanned = rows.first(MAX_SCAN_RESULTS)
      latest = scanned.uniq { |result| [ result.evaluation_scenario_id, result.provider, result.model ] }
      candidates = latest.select { |result| candidate?(result) }

      {
        cards: candidates.first(limit).map { |result| result_card(result, type: "demo_candidate") },
        coverage: {
          scanned: scanned.size, scan_limit: MAX_SCAN_RESULTS, cohorts: latest.size,
          eligible: candidates.size, returned: [ candidates.size, limit ].min, limit: limit,
          truncated: rows.size > MAX_SCAN_RESULTS || candidates.size > limit
        },
        caveats: [ PROVENANCE_CAVEAT, RUBRIC_CAVEAT,
          "Search covers the newest recorded terminal results within the scan limit; untested scenarios and runs without results provide no passing evidence." ]
      }
    end

    def read_evaluation_run(evaluation_id:, run_id:)
      evaluation = evaluations_scope(evaluation_id: evaluation_id).includes(:agent).first!
      run = evaluation.evaluation_runs.find(run_id)
      # A long suite's first questions may all pass. Keep failures visible in
      # the bounded excerpt, then pending and successful cases, rather than
      # making an error late in the suite impossible for the assistant to read.
      rows = run.scenario_results.preload(:agent_run).order(result_priority, :id).limit(MAX_REPORT_RESULTS + 1).to_a
      results = rows.first(MAX_REPORT_RESULTS)
      # Avoid fetching the same parent and agent for every result card.
      results.each { |result| result.association(:evaluation_run).target = run }
      run.association(:evaluation).target = evaluation

      {
        cards: [ run_summary(run, report: results.any?).merge(
          id: "evaluation-run-#{run.id}", type: "evaluation_run", title: "#{text(evaluation.name)} · run #{run.id}",
          agent_id: evaluation.agent_id, agent_name: text(evaluation.agent.name),
          caveats: [ PROVENANCE_CAVEAT, RUBRIC_CAVEAT, REPORT_CAVEAT ]
        ) ] + results.map { |result| result_card(result, type: "evaluation_result") },
        coverage: {
          scanned: results.size, limit: MAX_REPORT_RESULTS, truncated: rows.size > MAX_REPORT_RESULTS,
          selection: "failures_first", recorded_status_counts: run.scenario_results.group(:status).count
        },
        caveats: [ PROVENANCE_CAVEAT, RUBRIC_CAVEAT, REPORT_CAVEAT ]
      }
    end

    private

    def evaluations_scope(agent_id: nil, evaluation_id: nil)
      agents = agent_id.present? ? @agents.where(id: @agents.find(agent_id).id) : @agents
      scope = Evaluation.where(agent_id: agents.select(:id))
      return scope if evaluation_id.blank?

      scope.where(id: scope.find(evaluation_id).id)
    end

    def latest_runs(evaluation_ids)
      return {} if evaluation_ids.empty?

      table = EvaluationRun.quoted_table_name
      EvaluationRun.where(evaluation_id: evaluation_ids).where(
        "#{table}.id = (SELECT latest.id FROM #{table} latest WHERE latest.evaluation_id = #{table}.evaluation_id ORDER BY latest.created_at DESC, latest.id DESC LIMIT 1)"
      ).index_by(&:evaluation_id)
    end

    def terminal_results(evaluations)
      runs = EvaluationRun.where(evaluation_id: evaluations.select(:id), status: [ :complete, :failed ])
      run_table = EvaluationRun.arel_table
      EvaluationScenarioResult.joins(:evaluation_run)
        .where(evaluation_run_id: runs.select(:id), status: [ :passed, :failed, :errored ])
        .order(run_table[:created_at].desc, run_table[:id].desc, EvaluationScenarioResult.arel_table[:id].desc)
    end

    def result_priority
      statuses = EvaluationScenarioResult.statuses
      Arel::Nodes::Case.new(EvaluationScenarioResult.arel_table[:status])
        .when(statuses.fetch("errored")).then(0)
        .when(statuses.fetch("failed")).then(1)
        .when(statuses.fetch("pending")).then(2)
        .else(3)
    end

    def linked_replay(result)
      replay = result.agent_run
      return unless replay && replay.agent_id == result.evaluation_run.evaluation.agent_id
      return if replay.input_prompt.blank?

      replay
    end

    def candidate?(result)
      replay = linked_replay(result)
      result.passed? && result.output.present? && result.error_message.blank? && replay&.complete? &&
        result.provider != "mock" && replay.output_metadata&.dig("provider") != "mock"
    end

    def result_card(result, type:)
      run = result.evaluation_run
      replay = linked_replay(result)
      strength = check_strength(result)
      caveats = [ PROVENANCE_CAVEAT, RUBRIC_CAVEAT, REPORT_CAVEAT ]
      caveats << CONTEXT_CAVEAT unless replay
      caveats << "The replay did not record its instructions; the current agent instructions are not historical evidence." if replay && instructions_digest(replay).nil?
      caveats << "This evaluation run did not complete successfully; this result covers only its own recorded replay." unless run.complete?
      caveats << "The mock provider produces simulated test output, not real model evidence." if result.provider == "mock" || replay&.output_metadata&.dig("provider") == "mock"
      caveats << WEAK_CHECK_CAVEAT if strength == "shape_or_runtime_checks_only"
      caveats << "Recorded score names do not establish the rubric's meaning or strength." if strength == "unknown_rubric"

      {
        id: "evaluation-result-#{result.id}", type: type,
        title: replay ? text(replay.input_prompt) : "Recorded result #{result.id}",
        evaluation_id: run.evaluation_id, run_id: run.id, result_id: result.id,
        agent_id: run.evaluation.agent_id, agent_name: text(run.evaluation.agent.name),
        agent_run_id: replay&.id, replay_status: replay&.status, scenario_id: result.evaluation_scenario_id,
        path: "/evaluations/#{run.evaluation_id}/runs/#{run.id}/report",
        report_path: "/api/evaluations/#{run.evaluation_id}/runs/#{run.id}/report",
        status: result.status, evidence_status: candidate?(result) ? "historical_pass" : "recorded_result",
        recorded_prompt: replay && text(replay.input_prompt), output_excerpt: text(result.output),
        prompt_truncated: replay ? replay.input_prompt.length > TEXT_LIMIT : false,
        output_truncated: result.output.to_s.length > TEXT_LIMIT,
        provider: text(result.provider), model: text(result.model), recorded_at: result.created_at&.iso8601,
        completed_at: run.completed_at&.iso8601, score: result.score,
        recorded_scores: bounded_scores(result.scores), check_strength: strength,
        instructions_digest: instructions_digest(replay),
        tool_names: result.tool_names.first(20).map { |name| text(name, limit: 100) },
        fault: text(result.fault), error: safe_error(result.error_message), recommendation: text(result.recommendation),
        caveats: caveats
      }
    end

    def run_summary(run, report: false)
      {
        evaluation_id: run.evaluation_id, run_id: run.id, status: run.status,
        samples_evaluated: run.samples_evaluated, samples_passed: run.samples_passed,
        created_at: run.created_at&.iso8601, completed_at: run.completed_at&.iso8601,
        error: safe_error(run.error_message),
        path: report ? "/evaluations/#{run.evaluation_id}/runs/#{run.id}/report" : "/evaluations"
      }
    end

    def check_strength(result)
      keys = result.scores.to_h.keys.map(&:to_s)
      return "expectation_scores_recorded" if (keys & EXPECTATION_SCORE_KEYS).any?
      return "shape_or_runtime_checks_only" if keys.any? && (keys - SHAPE_SCORE_KEYS).empty?

      "unknown_rubric"
    end

    # Stored exceptions are arbitrary provider text, sometimes including keys,
    # authenticated URLs or entire request bodies. Keep status/fault categories
    # and the report link, but never export the exception to another provider.
    def safe_error(value)
      REDACTED_ERROR if value.present?
    end

    def bounded_scores(scores)
      scores.to_h.first(SCORE_LIMIT).to_h.transform_keys { |key| text(key, limit: 100) }.transform_values do |value|
        value.is_a?(Numeric) ? value : text(value, limit: 100)
      end
    end

    def instructions_digest(replay)
      instructions = replay&.output_metadata&.dig("instructions")
      Digest::SHA256.hexdigest(instructions) if instructions.is_a?(String) && instructions.present?
    end

    def bounded_limit(value, maximum)
      value.to_i.clamp(1, maximum)
    end

    def text(value, limit: TEXT_LIMIT)
      value&.to_s&.first(limit)
    end
  end
end
