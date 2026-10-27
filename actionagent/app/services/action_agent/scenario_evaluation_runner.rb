# frozen_string_literal: true

module ActionAgent
  # Runs a scenario evaluation: replays every selected scenario through the
  # agent once per candidate model and writes one EvaluationScenarioResult per
  # scenario × model plus a per-model summary and verdict on the run.
  #
  # The scoring, fault diagnosis and roll-up are ActiveAgent::Evals'; this
  # class supplies what only the dashboard knows — how to run the agent
  # (Agent#test_execute with a model override), where to persist each result,
  # how to price tokens, and which judge model the owner has credentials for.
  #
  # The run's `scores` keep the shape the Evaluations UI renders — criterion
  # => stats, or criterion => { model => stats } when comparing — and add
  # underscore-prefixed summaries:
  #
  #   "_models"          — per model: pass rate, mean score, latency, tokens, cost, fault counts
  #   "_recommendations" — faults grouped across scenarios with the fix each calls for
  #   "_verdict"         — the best model and why (judge-written when a judge is available)
  #   "_comparison"      — when comparing models: each model's pass rate with its
  #                        interval, every pair's difference and whether it is
  #                        decisive (ActiveAgent::Evals::Comparison)
  #   "_selection"       — the scenarios and models this run covered, and
  #                        the checkout sandbox it replayed against, if any
  #
  # A selection's `sandbox_id` names a checkout sandbox whose app runtime
  # every replay reaches beside the agent's own MCP servers, as if the agent
  # listed it (see Api::RunSandbox, which checked the caller owns it). The
  # agent is not changed. The runtime is resolved again here, among the
  # agent's owner's sessions, since the run may start well after it was
  # asked for; one that is no longer live fails the run rather than
  # replaying without the tools it was meant to test.
  #
  # A selection with `browser` true (a run of a project's evaluation, see
  # ProjectEvaluationJob) also gives every replay that sandbox's browser:
  # one already running, or one started headless with the project's saved
  # sign-in before the first replay, on a backend that runs browsers.
  # `mount_url`, the dashboard's absolute mount URL, is where a browser
  # started here posts its recording. Each replay's browser opens at the
  # project's start URL. A browser that cannot start fails the run before
  # any replay, and one started here is stopped once the run ends.
  class ScenarioEvaluationRunner < EvaluationRunnerService
    Evals = ActiveAgent::Evals

    # The providers a candidate model name resolves against. `mock` is the
    # framework's test double, accepted so the test suite can compare cohorts
    # offline.
    CANDIDATE_PROVIDERS = (Agent::PROVIDERS + %w[mock]).freeze

    # `run` is an EvaluationRun created ahead of time (by run_later!, so the
    # UI can show it pending while the job waits); absent, one is created here.
    def self.call(evaluation, selection: {}, run: nil)
      new(evaluation, selection: selection, run: run).call
    end

    # The caller a replay of +owner+'s agent runs on behalf of, which is also
    # who its provider credentials are resolved for: +owner+, when the
    # install owns agents per user. A run with no caller reads, through any
    # host scope, as "no access" — every tool answers empty and the suite
    # grades an agent that never saw a row — so the person the evaluation
    # belongs to is the right default, as the key's owner is over MCP. An
    # account is who is billed, not who is allowed (see Api::BaseController
    # #agent_actor), so a multi-tenant install replays unattributed unless a
    # host adapter (ActionAgent.scenario_evaluation_adapter_resolver) runs
    # the suite itself.
    def self.replay_actor_for(owner)
      return nil if ActionAgent.multi_tenant? || ActionAgent.user_class.blank?

      owner
    end

    def initialize(evaluation, selection: {}, run: nil)
      super(evaluation)
      @selection = (selection || {}).to_h.with_indifferent_access
      @run = run
    end

    def call
      scenarios = selected_scenarios
      specs = model_specs
      run = @run || @evaluation.evaluation_runs.create!(status: :pending)
      run.update!(status: :running, selection: selection_summary(scenarios, specs))
      ensure_sandbox_live!

      if scenarios.empty?
        run.update!(status: :failed, error_message: "No scenarios selected — add scenarios to the evaluation or widen the selection",
          completed_at: Time.current)
        return run
      end

      ensure_browser_live!

      adapter = ActionAgent.scenario_evaluation_adapter_resolver&.call(@evaluation)
      judge_provider if adapter.nil? && @evaluation.judge_model.present?
      return fan_out!(run, scenarios, specs) if fan_out?(adapter)

      records = scenarios.index_by(&:key)
      tasks = scenarios.map { |scenario| Evals::Scenario.from_hash(scenario.as_json_summary) }
      expected = tasks.product(specs).map { |task, spec| [ task.key, spec.label ] }
      # Every result tests membership twice, so look the pairs up in a set;
      # `expected` stays an array for the completeness comparison below, and
      # `persisted` sorts the same way either way.
      allowed = expected.to_set
      persisted = Set.new
      on_result = lambda do |result|
        pair = [ result.scenario.key, result.label ]
        raise ArgumentError, "unexpected or duplicate scenario evaluation result" unless allowed.include?(pair) && !persisted.include?(pair)

        persist(run, records.fetch(result.scenario.key), result)
        persisted << pair
      end
      report = if adapter
        raise ArgumentError, "scenario evaluation adapter must be callable" unless adapter.respond_to?(:call)

        # The default path meters each replay itself (see #replay). An adapter
        # runs the agent in the host's own runtime, out of reach of that call,
        # so the execution is counted here as each result lands — one per
        # scenario x model, the same unit. Otherwise a host that adapts the
        # replay is silently unmetered unless it remembers to meter itself.
        metered = lambda do |result|
          ActionAgent.record_usage(owner, :execution)
          on_result.call(result)
        end
        adapter.call(evaluation: @evaluation, owner: owner, scenarios: tasks, models: specs, on_result: metered)
      else
        ensure_judge_defined_kpis! if @evaluation.judge_defined?
        default_report(tasks, specs, on_result)
      end
      raise ArgumentError, "scenario evaluation adapter must return an ActiveAgent::Evals::Report" unless report.is_a?(Evals::Report)
      reported = report.results.map { |result| [ result.scenario.key, result.label ] }
      unless reported.sort == expected.sort && persisted.sort == expected.sort
        raise ArgumentError, "scenario evaluation adapter must report and persist every selected scenario and model"
      end

      run.update!(
        status: :complete,
        scores: scores_for(report, run),
        samples_evaluated: report.results.size,
        samples_passed: report.results.count(&:passed?),
        error_message: discovery_warning,
        completed_at: Time.current
      )
      run
    rescue StandardError => e
      run&.update!(status: :failed, error_message: e.message, completed_at: Time.current)
      raise
    ensure
      stop_started_browser
    end

    # --- fan-out (EvaluationReplayJob, EvaluationJudgeJob) -----------------
    #
    # With ActionAgent.scenario_evaluation_fan_out on, #call enqueues one
    # EvaluationReplayJob per scenario x model and returns the run still
    # running. Each replay is stored as a pending result and scored by its
    # own EvaluationJudgeJob, so the agent's next replay need not wait for
    # the judge. The job that scores the last pending result completes the
    # run with the same scores the sequential path writes.
    #
    # The agent's tool roster is discovered once, before the replays, and
    # kept with the run's bookkeeping (scores["_fan_out"]) for every job to
    # read, as the sequential path resolves it once per run: a diagnosis
    # names the same tools whichever job wrote it, and the run's discovery
    # warning does not depend on which job completed the run.

    # Replays one scenario under one model and stores the answer as a pending
    # result, then enqueues its scoring. A result already stored for the
    # pair (a retried job) is not replayed again.
    def replay_scenario!(run, scenario_id, spec_value)
      return unless run.running?

      scenario = @evaluation.scenarios.find(scenario_id)
      spec = model_spec_from(spec_value)
      row = stored_result(run, scenario, spec)
      unless row
        task = Evals::Scenario.from_hash(scenario.as_json_summary)
        replay = fan_out_replay(task, spec)
        row = run.with_lock { stored_result(run, scenario, spec) || store_replay(run, scenario, task, spec, replay) }
      end
      EvaluationJudgeJob.perform_later(row.id, @selection.to_h, run.id) if row.pending?
      row
    end

    # Scores, diagnoses and stores one pending result, then completes the run
    # when it was the last.
    #
    # A job delivered again for a result that is already scored, or that a
    # concurrent delivery has claimed, scores nothing. It still checks
    # whether the run is complete: the earlier delivery may have stored the
    # last result and stopped before completing the run.
    def judge_result!(row)
      run = row.evaluation_run
      return unless run.running?
      return finish_fan_out!(run) unless row.pending? && claim_result!(row)

      spec = fan_out_specs(run).fetch([ row.provider.to_s, row.model ]) do
        Evals::ModelSpec.new(label: row.model, provider: row.provider.to_s, model: row.model)
      end
      result = fan_out_scorer(run).evaluate(Evals::Scenario.from_hash(row.evaluated_scenario), spec, replay_from(row))
      row.update!(
        status: result.status,
        score: result.score,
        scores: result.scores,
        fault: result.fault,
        recommendation: result.recommendation,
        diagnosis: (result.diagnosis || {}).merge(row.diagnosis.to_h.slice("_replay_metadata", "_scenario_snapshot"))
          .merge("_judge_usage" => judge_usage).compact
      )
      # The result now holds what its scoring cost; whatever this runner asks
      # the judge from here on (the verdict, when it completes the run) is the
      # run's own.
      @judge_usage = nil
      finish_fan_out!(run)
    end

    # Stores +error+ as the result of a pair whose job failed outside the
    # replay (which records its own errors), so the run still completes. A
    # scenario removed from the suite during the run has no result to
    # store; the run completes without it (see #finish_fan_out!).
    def fail_result!(run, scenario_id, spec_value, error)
      return unless run.running?

      scenario = @evaluation.scenarios.find_by(id: scenario_id)
      if scenario
        spec = model_spec_from(spec_value)
        run.with_lock do
          row = stored_result(run, scenario, spec)
          task = Evals::Scenario.from_hash(scenario.as_json_summary)
          row ||= store_replay(run, scenario, task, spec, Evals::Replay.failed(error))
          row.update!(status: :errored, error_message: row.error_message.presence || error_text(error)) if row.pending?
        end
      end
      finish_fan_out!(run)
    end

    # Marks a pending result errored when its scoring job failed, so the run
    # still completes.
    def fail_judging!(row, error)
      run = row.evaluation_run
      row.update!(status: :errored, error_message: [ row.error_message.presence, "Scoring failed: #{error_text(error)}" ].compact.join(" ")) if row.pending?
      finish_fan_out!(run)
    end

    # Completes the run once every selected scenario x model has a scored
    # result, with the scores, verdict and judge usage a sequential run
    # writes. A scenario removed from the suite during the run is no longer
    # waited for (its results went with it), so the run completes without it.
    #
    # Nothing is computed under a lock. The verdict is a judge call, and a
    # lock on the run is, on SQLite, the write lock on the whole database:
    # held for the call, it would stall every other writer. The lock covers
    # only the check that the run is still running and the one write that
    # completes it. Of two jobs that both find the run finished, one
    # completes it and the other's work is dropped, at the cost of a second
    # verdict call in that rare tie.
    def finish_fan_out!(run)
      run.reload
      return unless run.running?

      specs = fan_out_specs(run)
      rows = run.scenario_results.includes(:agent_run).to_a
      return if rows.size < expected_results(run, specs) || rows.any?(&:pending?)

      attributes = begin
        completion_attributes(run, rows, specs)
      rescue StandardError => e
        { status: :failed, error_message: e.message, completed_at: Time.current }
      end
      run.with_lock do
        run.update!(attributes) if run.running?
      end
    end

    private

    def fan_out?(adapter)
      ActionAgent.scenario_evaluation_fan_out == true && adapter.nil? && !browser_requested? &&
        Evals::Runner.instance_method(:initialize).parameters.any? { |_type, name| name == :refine_gate }
    end

    def fan_out!(run, scenarios, specs)
      refuse_duplicate_specs!(specs)
      ensure_judge_defined_kpis! if @evaluation.judge_defined?
      # Discovered here, before any lock is taken and before a sandbox the
      # run replays against can expire; the jobs read it from the run.
      roster = { "tools" => tool_roster, "discovery_warning" => discovery_warning }
      update_fan_out_state!(run) do |state|
        state.merge(roster).merge(judge_usage ? { "judge_usage" => judge_usage } : {})
      end

      selection = @selection.to_h
      scenarios.product(specs).each do |scenario, spec|
        EvaluationReplayJob.perform_later(run.id, scenario.id, spec.to_h, selection)
      end
      run
    end

    # A fanned-out run keys its results by provider and model, where the
    # sequential path keys them by label, so one model listed under two
    # labels ("gpt-5-mini" and "openai/gpt-5-mini") would be replayed once
    # and reported under one of them; the run refuses the selection instead.
    def refuse_duplicate_specs!(specs)
      duplicates = specs.group_by { |spec| [ spec.provider, spec.model ] }.select { |_pair, group| group.size > 1 }
      return if duplicates.empty?

      names = duplicates.map { |(provider, model), group| "#{provider}/#{model} as #{group.map(&:label).join(' and ')}" }
      raise ArgumentError, "the same model is listed more than once (#{names.to_sentence}); list each provider/model once"
    end

    def model_spec_from(value)
      value = value.to_h.stringify_keys
      Evals::ModelSpec.new(label: value["label"].presence || value["model"], provider: value["provider"].to_s, model: value["model"])
    end

    # The run's candidate models, in the order it selected them, keyed by
    # provider and model as a result row records them.
    def fan_out_specs(run)
      Array(run.selection&.dig("models")).filter_map do |entry|
        model_spec_from(entry) if entry.is_a?(Hash) && entry["model"].present?
      end.index_by { |spec| [ spec.provider, spec.model ] }
    end

    def stored_result(run, scenario, spec)
      run.scenario_results.find_by(evaluation_scenario_id: scenario.id, model: spec.model, provider: spec.provider)
    end

    # How many results the run waits for: one per selected scenario still in
    # the suite, per model.
    def expected_results(run, specs)
      ids = Array(run.selection&.dig("scenario_ids"))
      @evaluation.scenarios.where(id: ids).count * specs.size
    end

    # Claims a pending result for this job before it is scored. Of two judge
    # jobs delivered for one result (a replay job delivered again after it
    # enqueued the first), only the one whose claim lands scores it, so the
    # judge is asked once and the run's meter counts each call once. The
    # claim is a conditional write on the row's timestamp: it holds no lock
    # while the judge is asked, and a row whose claimant then stops is still
    # pending for the next delivery.
    def claim_result!(row)
      EvaluationScenarioResult.where(id: row.id, status: :pending, updated_at: row.updated_at).update_all(updated_at: Time.current) == 1
    end

    # What Evals::Runner does with a replay that raises: an errored replay,
    # scored like any other.
    def fan_out_replay(task, spec)
      replay(task, spec)
    rescue StandardError => e
      Evals::Replay.failed(e)
    end

    def store_replay(run, scenario, task, spec, replay)
      run.scenario_results.create!(
        scenario: scenario,
        agent_run_id: replay.metadata["agent_run_id"],
        model: spec.model,
        provider: spec.provider,
        status: :pending,
        output: replay.answer.to_s.byteslice(0, 20_000).to_s.scrub.presence,
        tool_calls: replay.tool_calls,
        duration_ms: replay.duration_ms,
        input_tokens: replay.input_tokens,
        output_tokens: replay.output_tokens,
        cost: replay.cost,
        diagnosis: {
          "_replay_metadata" => replay.metadata,
          "_scenario_snapshot" => task.to_h.merge(expectations: task.expectations)
        },
        error_message: replay.error
      )
    end

    # The stored replay, with the answer as the agent run recorded it. The
    # result keeps the first 20,000 bytes of the answer to show; a rule or
    # an expectation (contains, not_contains, min_length) reads all of it, as
    # it does on the sequential path, so a long answer scores the same
    # fanned out.
    def replay_from(row)
      Evals::Replay.new(
        answer: row.agent_run&.output.presence || row.output, tool_calls: row.tool_calls, duration_ms: row.duration_ms,
        input_tokens: row.input_tokens, output_tokens: row.output_tokens, error: row.error_message,
        cost: row.cost&.to_f, metadata: row.replay_metadata
      )
    end

    # A Runner that scores one replay. Its refine_gate shares the run-wide
    # judge_limit with every other result's scorer, and its roster is the one
    # discovered when the run fanned out (a run fanned out before the roster
    # was kept discovers its own).
    def fan_out_scorer(run)
      Evals::Runner.new(
        scenarios: [],
        models: [],
        criteria: sample_criteria,
        judge: evals_judge,
        available_tools: fan_out_state(run).fetch("tools") { tool_roster },
        instructions: @evaluation.agent.instructions,
        agent_name: @evaluation.agent.name,
        threshold: PASS_THRESHOLD,
        replay: ->(*) { raise ArgumentError, "a fanned-out result is scored from its stored replay" },
        refine_gate: -> { reserve_refinement!(run) }
      )
    end

    def reserve_refinement!(run)
      reserved = false
      update_fan_out_state!(run) do |state|
        count = state["refinements"].to_i
        next state if count >= Evals::Runner::DEFAULT_JUDGE_LIMIT

        reserved = true
        state.merge("refinements" => count + 1)
      end
      reserved
    end

    # The run's fan-out bookkeeping, kept in scores["_fan_out"] until the run
    # completes and its scores are written: the tool roster and discovery
    # warning found before the replays, the judge usage spent before them
    # (judge-defined KPIs), and the recommendations reserved so far.
    def fan_out_state(run)
      state = run.scores.is_a?(Hash) ? run.scores["_fan_out"] : nil
      state.is_a?(Hash) ? state : {}
    end

    # Changes the bookkeeping under the run's lock. A completed run's scores
    # are left as written: a reservation that lands after the last result
    # has nothing to reserve.
    def update_fan_out_state!(run)
      run.with_lock do
        next unless run.running?

        scores = run.scores.is_a?(Hash) ? run.scores : {}
        run.update!(scores: scores.merge("_fan_out" => yield(fan_out_state(run))))
      end
    end

    # What completes the run: the attributes the sequential path writes at
    # the end of #call, from the stored results.
    def completion_attributes(run, rows, specs)
      if rows.empty?
        return { status: :failed, error_message: "Every selected scenario was removed during the run", completed_at: Time.current }
      end

      order = specs.keys
      rows = rows.sort_by do |row|
        [ row.evaluated_scenario["position"].to_i, row.evaluation_scenario_id, order.index([ row.provider.to_s, row.model ]) || order.size ]
      end
      results = rows.map do |row|
        Evals::Result.new(
          scenario: Evals::Scenario.from_hash(row.evaluated_scenario),
          spec: specs.fetch([ row.provider.to_s, row.model ]) { model_spec_from(row.attributes.slice("provider", "model")) },
          replay: replay_from(row),
          scores: row.scores.to_h, score: row.score, status: row.status,
          diagnosis: row.evaluation_diagnosis.presence
        )
      end
      report = Evals::Report.new(results: results, models: specs.values, judge: evals_judge,
                                 instructions: @evaluation.agent.instructions, threshold: PASS_THRESHOLD)
      state = fan_out_state(run)

      # The other jobs' judge calls go into this runner's meter before the
      # verdict is asked for, so the run's usage, and anything scores_for
      # reads from the meter, covers every call once.
      @judge_usage = combined_judge_usage([ state["judge_usage"], *rows.map { |row| row.diagnosis.to_h["_judge_usage"] }, judge_usage ])

      {
        status: :complete,
        scores: scores_for(report, run),
        samples_evaluated: results.size,
        samples_passed: results.count(&:passed?),
        error_message: state.key?("discovery_warning") ? state["discovery_warning"] : discovery_warning,
        completed_at: Time.current
      }
    end

    # Sums the judge usage of the run's parts into the one meter
    # scores["_judge_usage"] holds for a sequential run.
    def combined_judge_usage(parts)
      parts = parts.select { |part| part.is_a?(Hash) }
      return nil if parts.empty?

      costs = parts.filter_map { |part| part["cost"] }
      {
        "calls" => parts.sum { |part| part["calls"].to_i },
        "input_tokens" => parts.sum { |part| part["input_tokens"].to_i },
        "output_tokens" => parts.sum { |part| part["output_tokens"].to_i },
        "cost" => costs.any? ? costs.sum.round(6) : nil,
        "model" => parts.filter_map { |part| part["model"] }.first,
        "by_kind" => tally(parts, "by_kind"),
        "models" => tally(parts, "models")
      }
    end

    def tally(parts, key)
      parts.each_with_object(Hash.new(0)) do |part, counts|
        part[key].to_h.each { |name, count| counts[name] += count.to_i }
      end.to_h
    end

    def error_text(error)
      error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    end

    def default_report(tasks, specs, on_result)
      Evals::Runner.new(
        scenarios: tasks,
        models: specs,
        criteria: sample_criteria,
        judge: evals_judge,
        available_tools: tool_roster,
        instructions: @evaluation.agent.instructions,
        agent_name: @evaluation.agent.name,
        threshold: PASS_THRESHOLD,
        replay: ->(scenario, spec) { replay(scenario, spec) },
        on_result: on_result
      ).call
    end

    # --- selection --------------------------------------------------------

    def selected_scenarios
      scope = @evaluation.scenarios.enabled.ordered
      scope = scope.where(id: Array(@selection[:scenario_ids])) if @selection[:scenario_ids].present?
      scope = scope.where(key: Array(@selection[:keys])) if @selection[:keys].present?
      scope = scope.in_group(@selection[:group]) if @selection[:group].present?
      scope.to_a
    end

    # The models to compare: an explicit selection, else the evaluation's
    # compare_models, else the agent as configured.
    def model_specs
      names = Array(@selection[:models]).presence || @evaluation.compare_models
      specs = Evals::ModelSpec.parse_all(names, default_provider: @evaluation.agent.provider, providers: CANDIDATE_PROVIDERS)
      # parse_all resolves a bare name against `providers:` but passes through a
      # `provider/model` whose provider is not in that list, so the run would
      # otherwise reach the replay with a provider nothing can serve.
      unsupported = specs.map(&:provider).uniq - CANDIDATE_PROVIDERS
      raise ArgumentError, "unsupported model provider: #{unsupported.to_sentence}" if unsupported.any?

      return specs if specs.any?

      [ Evals::ModelSpec.new(label: @evaluation.agent.model, provider: @evaluation.agent.provider, model: @evaluation.agent.model) ]
    end

    def selection_summary(scenarios, specs)
      {
        "scenario_ids" => scenarios.map(&:id),
        "scenario_keys" => scenarios.map(&:key),
        "group" => @selection[:group].presence,
        "models" => specs.map(&:to_h),
        "sandbox" => sandbox_summary,
        "browser" => browser_requested? ? { "server_key" => "#{SandboxSession::BROWSER_SERVER_PREFIX}#{@selection[:sandbox_id]}" } : nil
      }.compact
    end

    # --- sandbox ----------------------------------------------------------

    # "sandbox:<session_id>" for a run against a checkout sandbox, or nil.
    def sandbox_server_key
      id = @selection[:sandbox_id]
      "#{SandboxSession::RUNTIME_SERVER_PREFIX}#{id}" if id.is_a?(String) && id.present?
    end

    def sandbox_session
      return @sandbox_session if defined?(@sandbox_session)

      @sandbox_session = sandbox_server_key && SandboxSession.for_owner(owner).find_by(session_id: @selection[:sandbox_id])
    end

    # What the run records about its sandbox: which checkout, never its
    # token.
    def sandbox_summary
      return nil unless sandbox_server_key

      {
        "session_id" => @selection[:sandbox_id],
        "server_key" => sandbox_server_key,
        "repository" => sandbox_session&.repository,
        "repository_ref" => sandbox_session&.repository_ref
      }.compact
    end

    def ensure_sandbox_live!
      return unless sandbox_server_key
      return if SandboxSession.runtime_server_entry(sandbox_server_key, owner: owner)

      raise ArgumentError, "Sandbox #{@selection[:sandbox_id]} is no longer running; start it again, or run without it"
    end

    # --- browser ----------------------------------------------------------

    # Whether the replays reach the sandbox's browser: asked for, and
    # running or startable on the sandbox's backend.
    def browser_requested?
      return @browser_requested if defined?(@browser_requested)

      @browser_requested = sandbox_server_key.present? && ActiveModel::Type::Boolean.new.cast(@selection[:browser]) == true &&
        sandbox_session.present? && (sandbox_session.browser_running? || SandboxBrowser.orchestrator!.supports?(:start_browser))
    rescue SandboxBrowser::Error
      @browser_requested = false
    end

    # The project the selected sandbox was booted for, or nil.
    def sandbox_project
      return @sandbox_project if defined?(@sandbox_project)

      @sandbox_project = sandbox_session&.project_id && Project.find_by(id: sandbox_session.project_id)
    end

    def ensure_browser_live!
      return unless browser_requested?

      sandbox = sandbox_session
      unless sandbox.browser_running?
        denial = ActionAgent.quota_denial(sandbox.metering_owner, :browser_minutes)
        raise ArgumentError, "The sandbox's browser could not start: the plan allows no more browser minutes" if denial.present?

        _, @started_browser = SandboxBrowser.ensure_running!(sandbox,
          recording_url: SandboxBrowser.recording_url_for(@selection[:mount_url]), storage_state: sandbox_project&.saved_storage_state)
      end
      @sandbox_session = sandbox.reload
    rescue SandboxBrowser::Error => e
      raise ArgumentError, "The sandbox's browser could not start: #{e.message}"
    end

    # Stops the browser ensure_browser_live! started, which completes its
    # recording and stops its minutes. One that was already running is left
    # running.
    def stop_started_browser
      return unless @started_browser

      @started_browser = false
      sandbox = sandbox_session.reload
      SandboxBrowser.stop(sandbox) if SandboxBrowser::STARTED.include?(sandbox.browser_status)
    rescue SandboxBrowser::Error, ActiveRecord::RecordNotFound => e
      Rails.logger.warn("[ActionAgent] evaluation #{@evaluation.id}: could not stop the browser it started: #{e.message}")
    end

    # Opens the project's start URL in the sandbox's browser, so each replay
    # starts on the same page. A browser that does not answer is left to the
    # replay, which fails when it cannot reach it.
    def open_start_url
      return unless browser_requested?

      SandboxBrowserDriver.new(sandbox_session).open(sandbox_project&.start_url.presence || "/")
    rescue SandboxBrowserDriver::Error => e
      Rails.logger.warn("[ActionAgent] evaluation #{@evaluation.id}: could not open the start URL: #{e.message}")
    end

    # --- replay -----------------------------------------------------------

    def replay(scenario, spec)
      # One execution per replay, reported to the host before the run starts
      # (the order SandboxesController#compare uses), so it is counted even
      # when the run fails.
      ActionAgent.record_usage(owner, :execution)
      open_start_url

      agent_run = @evaluation.agent.test_execute(
        scenario.prompt,
        model_override: spec.model,
        provider_override: spec.provider,
        actor: replay_actor,
        runtime_sandbox: sandbox_server_key
      )
      # A replay has nobody to answer, so a paused run ends here as an error.
      paused = agent_run.awaiting_input?
      agent_run.cancel!("Paused for input during an evaluation replay") if paused

      Evals::Replay.new(
        answer: agent_run.output,
        tool_calls: tool_calls_for(agent_run),
        duration_ms: agent_run.calculated_duration_ms,
        input_tokens: agent_run.input_tokens,
        output_tokens: agent_run.output_tokens,
        error: replay_error(agent_run, paused),
        cost: ModelPricing.estimate(model: spec.model, provider: spec.provider, input_tokens: agent_run.input_tokens,
                                    output_tokens: agent_run.output_tokens),
        metadata: { "agent_run_id" => agent_run.id }
      )
    end

    def replay_error(agent_run, paused)
      return "paused for input" if paused

      agent_run.failed? ? agent_run.error_message.presence || "run failed" : nil
    end

    # The caller a replay runs on behalf of: the evaluation's owner, when the
    # install owns agents per user. A run with no caller reads, through any
    # host scope, as "no access" — every tool answers empty and the suite
    # grades an agent that never saw a row — so the person the evaluation
    # belongs to is the right default, as the key's owner is over MCP. An
    # account is who is billed, not who is allowed (see Api::BaseController
    # #agent_actor), so a multi-tenant install replays unattributed unless a
    # host adapter (ActionAgent.scenario_evaluation_adapter_resolver) runs
    # the suite itself.
    def replay_actor
      self.class.replay_actor_for(owner)
    end

    # Each tool call the run made, rebuilt from the run's progress events
    # (AgentRun#append_event pairs a "started" event with its "done"/"error"
    # by eid). Falls back to the bare names in the run's metadata for a run
    # recorded without events.
    def tool_calls_for(agent_run)
      events = Array(agent_run.logs).select { |event| event.is_a?(Hash) && %w[tool agent].include?(event["kind"]) }
      if events.empty?
        return Array(agent_run.output_metadata&.dig("tool_calls")).map { |name| { "name" => name.to_s } }
      end

      events.group_by { |event| event["eid"] }.values.map do |group|
        started = group.find { |event| event["status"] == "started" }
        finished = group.find { |event| %w[done error].include?(event["status"]) }
        label = (started || finished)["label"].to_s

        {
          "name" => label.sub(/\s*→.*\z/, ""),
          "arguments" => parse_json(started&.dig("detail")),
          "error" => finished&.dig("status") == "error",
          "detail" => finished&.dig("detail"),
          "duration_ms" => finished&.dig("duration_ms")
        }.compact
      end
    end

    def parse_json(text)
      return nil if text.blank?

      JSON.parse(text)
    rescue JSON::ParserError
      text
    end

    # --- persistence ------------------------------------------------------

    def persist(run, scenario, result)
      run.scenario_results.create!(
        scenario: scenario,
        agent_run_id: result.replay.metadata["agent_run_id"],
        model: result.model,
        provider: result.provider,
        status: result.status,
        score: result.score,
        scores: result.scores,
        output: result.replay.answer.to_s.byteslice(0, 20_000).to_s.scrub.presence,
        tool_calls: result.replay.tool_calls,
        duration_ms: result.replay.duration_ms,
        input_tokens: result.replay.input_tokens,
        output_tokens: result.replay.output_tokens,
        cost: result.replay.cost,
        fault: result.fault,
        recommendation: result.recommendation,
        diagnosis: (result.diagnosis || {}).merge(
          "_replay_metadata" => result.replay.metadata,
          "_scenario_snapshot" => result.scenario.to_h.merge(expectations: result.scenario.expectations)
        ),
        error_message: result.replay.error
      )
    end

    def scores_for(report, run)
      scores = report.criterion_scores
      scores["_models"] = report.summary_by_model
      scores["_recommendations"] = report.recommendations
      scores["_verdict"] = report.verdict if report.comparing?
      # The framework gained Report#comparison after the oldest activeagent
      # this engine runs against.
      comparison = report.comparison if report.respond_to?(:comparison)
      scores["_comparison"] = comparison if comparison
      scores["_selection"] = run.selection
      scores["_metadata"] = report.metadata
      scores["_judge_label"] = report.judge_label || report.judge&.label
      # The judge's own spend, apart from the replays' (which the results
      # carry and EvaluationRun#usage sums). A host adapter that runs its own
      # judge is out of reach of this meter, so its runs record none.
      if judge_usage
        scores["_judge_usage"] = judge_usage
        name_judge!(scores, report.judge&.label)
      end
      scores
    end

    # Records who judged once the calls are in. A judge with no model pinned
    # started out labelled by its provider; it is renamed after the model
    # that answered, here and on the verdict it wrote.
    def name_judge!(scores, provisional)
      scores["_judge"] = judge_descriptor
      label = judge_display_label
      return unless label && provisional && scores["_judge_label"] == provisional

      scores["_judge_label"] = label
      scores["_verdict"]["judge"] = label if scores["_verdict"].is_a?(Hash) && scores["_verdict"]["judge"] == provisional
    end

    # --- judge ------------------------------------------------------------

    def sample_criteria
      @sample_criteria ||= @evaluation.criteria.reject do |criterion|
        Evaluation::TELEMETRY_CRITERION_TYPES.include?(criterion["type"])
      end
    end

    # Every tool the agent could actually call, for the diagnosis roster: the
    # engine's own toolbox plus whatever its MCP servers serve.
    #
    # Listing only the toolbox understated the roster, so a diagnosis could
    # report "none of the available tools covers this task" while naming a list
    # the agent's MCP tools were missing from.
    def tool_roster
      runtime_tools.tools
    end

    # Discovery failures from the roster above, keyed by server.
    def mcp_discovery_errors
      runtime_tools.discovery_errors
    end

    # The sandbox's browser is on the roster while it runs, as each replay
    # (Agent#test_execute) reaches it then.
    def mcp_dispatcher
      runtime_tools.dispatcher
    end

    def runtime_tools
      @runtime_tools ||= RuntimeToolRoster.new(
        @evaluation.agent, extra_server_keys: [ sandbox_server_key, sandbox_browser_key ].compact
      )
    end

    def sandbox_browser_key
      sandbox_session.browser_server_key if sandbox_session&.browser_running?
    end

    # A run whose every declared MCP server failed discovery scored an agent
    # that had no tools to call. The scores are real but meaningless — the
    # model answered from its own weights — so the run says so rather than
    # leaving the cause in a log line (#425).
    def discovery_warning
      errors = mcp_discovery_errors
      return nil if errors.empty?

      prefix = if mcp_dispatcher.all_servers_failed?
        "Every MCP server this agent declares failed tool discovery, so it ran with no MCP tools " \
        "and any specifics in its answers are unverified."
      else
        "Some of this agent's MCP servers failed tool discovery, so part of its toolset was unavailable."
      end

      "#{prefix} #{errors.values.join(' ')}"
    end

    # The judge the evaluation's owner has credentials for, wrapped for the
    # evaluation core; nil when none is configured, in which case scoring
    # stays on rules and expectations. The block takes `kind:` so each call
    # is metered under what it was for (EvaluationRunnerService#judge_generate).
    def evals_judge
      return nil unless judge_available?

      @evals_judge ||= Evals::Judge.new(label: judge_display_label) do |instructions:, prompt:, kind:|
        judge_generate(kind, message: prompt, instructions: instructions).message&.content
      end
    end
  end
end
