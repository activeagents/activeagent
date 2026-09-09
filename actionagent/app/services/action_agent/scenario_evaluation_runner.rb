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
  #   "_selection"       — the scenarios and models this run covered
  class ScenarioEvaluationRunner < EvaluationRunnerService
    Evals = ActiveAgent::Evals

    # `run` is an EvaluationRun created ahead of time (by run_later!, so the
    # UI can show it pending while the job waits); absent, one is created here.
    def self.call(evaluation, selection: {}, run: nil)
      new(evaluation, selection: selection, run: run).call
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

      if scenarios.empty?
        run.update!(status: :failed, error_message: "No scenarios selected — add scenarios to the evaluation or widen the selection",
          completed_at: Time.current)
        return run
      end

      records = scenarios.index_by(&:key)
      tasks = scenarios.map { |scenario| Evals::Scenario.from_hash(scenario.as_json_summary) }
      expected = tasks.product(specs).map { |task, spec| [ task.key, spec.label ] }
      persisted = []
      on_result = lambda do |result|
        pair = [ result.scenario.key, result.label ]
        raise ArgumentError, "unexpected or duplicate scenario evaluation result" unless expected.include?(pair) && !persisted.include?(pair)

        persist(run, records.fetch(result.scenario.key), result)
        persisted << pair
      end
      adapter = ActionAgent.scenario_evaluation_adapter_resolver&.call(@evaluation)
      report = if adapter
        raise ArgumentError, "scenario evaluation adapter must be callable" unless adapter.respond_to?(:call)

        adapter.call(evaluation: @evaluation, owner: owner, scenarios: tasks, models: specs, on_result: on_result)
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
        completed_at: Time.current
      )
      run
    rescue StandardError => e
      run&.update!(status: :failed, error_message: e.message, completed_at: Time.current)
      raise
    end

    private

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
    # compare_models, else the agent as configured. `mock` is the framework's
    # test double, accepted so the test suite can compare cohorts offline.
    def model_specs
      names = Array(@selection[:models]).presence || @evaluation.compare_models
      specs = Evals::ModelSpec.parse_all(names, default_provider: @evaluation.agent.provider, providers: Agent::PROVIDERS + %w[mock])
      return specs if specs.any?

      [ Evals::ModelSpec.new(label: @evaluation.agent.model, provider: @evaluation.agent.provider, model: @evaluation.agent.model) ]
    end

    def selection_summary(scenarios, specs)
      {
        "scenario_ids" => scenarios.map(&:id),
        "scenario_keys" => scenarios.map(&:key),
        "group" => @selection[:group].presence,
        "models" => specs.map(&:to_h)
      }.compact
    end

    # --- replay -----------------------------------------------------------

    def replay(scenario, spec)
      # One execution per replay, reported to the host before the run starts
      # (the order SandboxesController#compare uses), so it is counted even
      # when the run fails.
      ActionAgent.record_usage(owner, :execution)

      agent_run = @evaluation.agent.test_execute(
        scenario.prompt,
        model_override: spec.model,
        provider_override: spec.provider
      )

      Evals::Replay.new(
        answer: agent_run.output,
        tool_calls: tool_calls_for(agent_run),
        duration_ms: agent_run.calculated_duration_ms,
        input_tokens: agent_run.input_tokens,
        output_tokens: agent_run.output_tokens,
        error: agent_run.failed? ? agent_run.error_message.presence || "run failed" : nil,
        cost: ModelPricing.estimate(model: spec.model, input_tokens: agent_run.input_tokens, output_tokens: agent_run.output_tokens),
        metadata: { "agent_run_id" => agent_run.id }
      )
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
        diagnosis: (result.diagnosis || {}).merge("_replay_metadata" => result.replay.metadata),
        error_message: result.replay.error
      )
    end

    def scores_for(report, run)
      scores = report.criterion_scores
      scores["_models"] = report.summary_by_model
      scores["_recommendations"] = report.recommendations
      scores["_verdict"] = report.verdict if report.comparing?
      scores["_selection"] = run.selection
      scores["_metadata"] = report.metadata
      scores
    end

    # --- judge ------------------------------------------------------------

    def sample_criteria
      @sample_criteria ||= @evaluation.criteria.reject do |criterion|
        Evaluation::TELEMETRY_CRITERION_TYPES.include?(criterion["type"])
      end
    end

    def tool_roster
      @tool_roster ||= AgentToolbox.definitions_for(@evaluation.agent.tools).to_h do |definition|
        [ definition[:name].to_s, definition[:description].to_s ]
      end
    end

    # The judge the evaluation's owner has credentials for, wrapped for the
    # evaluation core; nil when none is configured, in which case scoring
    # stays on rules and expectations.
    def evals_judge
      return nil unless judge_available?

      @evals_judge ||= Evals::Judge.new(label: @evaluation.judge_model.presence || judge_provider.to_s) do |instructions:, prompt:|
        judge_class.prompt(message: prompt, instructions: instructions).generate_now.message&.content
      end
    end
  end
end
