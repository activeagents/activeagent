# frozen_string_literal: true

module ActionAgent
  # Runs a scenario evaluation: replays every selected scenario through the
  # agent once per candidate model, scores each answer, diagnoses the ones
  # that fall short, and writes one EvaluationScenarioResult per
  # scenario × model plus a per-model summary and verdict on the run.
  #
  # Scoring combines the evaluation's sample criteria (the same rule and
  # llm_judge types EvaluationRunnerService applies to recorded generations)
  # with the scenario's own expectations — the tools it should call, the
  # content its answer must and must not contain. A scenario passes when it
  # produced an answer, met its expectations and scored at or above
  # PASS_THRESHOLD; anything else is assigned exactly one fault and a
  # recommendation by FaultDiagnosis, refined by the judge model when one is
  # configured.
  #
  # The run's `scores` keep the shape the Evaluations UI already renders —
  # criterion => stats, or criterion => { model => stats } when comparing —
  # and add underscore-prefixed summaries:
  #
  #   "_models"          — per model: pass rate, mean score, latency, tokens, cost, fault counts
  #   "_recommendations" — faults grouped across scenarios with the fix each calls for
  #   "_verdict"         — the best model and why (judge-written when a judge is available)
  #   "_selection"       — the scenarios and models this run covered
  class ScenarioEvaluationRunner < EvaluationRunnerService
    # Faults where a judge can add something the evidence alone cannot: what
    # tool to add, or how to change the instructions.
    JUDGE_REFINED_FAULTS = %w[missing_capability expected_tool_not_called low_quality missing_content].freeze
    JUDGE_DIAGNOSIS_LIMIT = 25

    Sample = Struct.new(:id, :prompt, :content, :duration_seconds, :output_tokens, keyword_init: true)

    # `run` is an EvaluationRun created ahead of time (by run_later!, so the
    # UI can show it pending while the job waits); absent, one is created here.
    def self.call(evaluation, selection: {}, run: nil)
      new(evaluation, selection: selection, run: run).call
    end

    def initialize(evaluation, selection: {}, run: nil)
      super(evaluation)
      @selection = (selection || {}).to_h.with_indifferent_access
      @run = run
      @judge_calls = 0
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

      ensure_judge_defined_kpis! if @evaluation.judge_defined?

      results = scenarios.flat_map do |scenario|
        specs.map { |spec| replay(run, scenario, spec) }
      end

      run.update!(
        status: :complete,
        scores: aggregate(results, specs),
        samples_evaluated: results.size,
        samples_passed: results.count(&:passed?),
        completed_at: Time.current
      )
      run
    rescue StandardError => e
      run&.update!(status: :failed, error_message: e.message, completed_at: Time.current)
      raise
    end

    private

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
      specs = ModelSpec.parse_all(names, default_provider: @evaluation.agent.provider)
      return specs if specs.any?

      [ ModelSpec.new(label: @evaluation.agent.model, provider: @evaluation.agent.provider, model: @evaluation.agent.model) ]
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

    def replay(run, scenario, spec)
      agent_run = @evaluation.agent.test_execute(
        scenario.prompt,
        model_override: spec.model,
        provider_override: spec.provider
      )
      tool_calls = tool_calls_for(agent_run)
      sample = Sample.new(
        id: agent_run.id,
        prompt: scenario.prompt,
        content: agent_run.output,
        duration_seconds: agent_run.calculated_duration_ms.to_f / 1000,
        output_tokens: agent_run.output_tokens
      )

      scores = score_scenario(scenario, sample, tool_calls)
      scored = scores.values.compact
      score = scored.any? ? (scored.sum / scored.size).round(3) : nil

      diagnosis = FaultDiagnosis.call(
        scenario: scenario, agent_run: agent_run, tool_calls: tool_calls,
        scores: scores, score: score, roster: tool_roster, threshold: PASS_THRESHOLD
      )
      diagnosis_hash = diagnosis&.to_h
      refine_diagnosis!(diagnosis_hash, scenario, agent_run, tool_calls) if diagnosis_hash

      run.scenario_results.create!(
        scenario: scenario,
        agent_run: agent_run,
        model: spec.model,
        provider: spec.provider,
        status: result_status(agent_run, diagnosis),
        score: score,
        scores: scores,
        output: agent_run.output.to_s.byteslice(0, 20_000).to_s.scrub.presence,
        tool_calls: tool_calls,
        duration_ms: agent_run.calculated_duration_ms,
        input_tokens: agent_run.input_tokens,
        output_tokens: agent_run.output_tokens,
        cost: ModelPricing.estimate(model: spec.model, input_tokens: agent_run.input_tokens, output_tokens: agent_run.output_tokens),
        fault: diagnosis&.fault,
        recommendation: diagnosis_hash&.dig("recommendation"),
        diagnosis: diagnosis_hash || {},
        error_message: agent_run.error_message
      ).tap { |result| result.define_singleton_method(:cohort) { spec.label } }
    end

    def result_status(agent_run, diagnosis)
      return :errored if agent_run.failed?

      diagnosis ? :failed : :passed
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

    # --- scoring ----------------------------------------------------------

    # criterion key => score, over the evaluation's sample criteria plus the
    # scenario's expectations. nil marks a criterion that could not be scored.
    def score_scenario(scenario, sample, tool_calls)
      scores = {}
      sample_criteria.each do |criterion|
        scores[criterion["key"]] = sample.content.present? ? score_sample(criterion, sample) : 0.0
      end

      called = tool_calls.map { |call| call["name"].to_s }
      if scenario.expected_tools.any?
        scores["expected_tools"] = (scenario.expected_tools & called).any? ? 1.0 : 0.0
      end
      if scenario.expected_patterns.any?
        hits = scenario.expected_patterns.count { |pattern| matches_pattern?(sample.content, "pattern" => pattern) }
        scores["expected_content"] = (hits.to_f / scenario.expected_patterns.size).round(3)
      end
      if scenario.forbidden_patterns.any?
        scores["forbidden_content"] = scenario.forbidden_patterns.any? { |pattern| matches_pattern?(sample.content, "pattern" => pattern) } ? 0.0 : 1.0
      end
      if tool_calls.any?
        scores["tools_succeeded"] = tool_calls.any? { |call| call["error"] } ? 0.0 : 1.0
      end

      scores
    end

    def sample_criteria
      @sample_criteria ||= @evaluation.criteria.reject do |criterion|
        Evaluation::TELEMETRY_CRITERION_TYPES.include?(criterion["type"])
      end
    end

    # The judge sees the user's message as well as the answer, so it can
    # score whether the task was done rather than whether the prose is good.
    def judge_prompt(criterion, sample)
      <<~PROMPT
        Criterion: #{criterion.dig('config', 'prompt').presence || criterion['key'].to_s.humanize}

        The user asked:
        ---
        #{sample.prompt.to_s.truncate(1_500)}
        ---

        The agent answered:
        ---
        #{sample.content.to_s.truncate(4_000)}
        ---

        Score the answer against the criterion from 0.0 (fails completely) to 1.0 (fully satisfies).
        Respond only with JSON: {"score": <float>}
      PROMPT
    end

    # --- diagnosis --------------------------------------------------------

    def tool_roster
      @tool_roster ||= AgentToolbox.definitions_for(@evaluation.agent.tools).map do |definition|
        { name: definition[:name].to_s, description: definition[:description].to_s }
      end
    end

    # Asks the judge for a sharper recommendation than the evidence alone
    # gives: which tool to add, or what to change in the instructions. Skipped
    # without a judge, for mechanical faults, and past JUDGE_DIAGNOSIS_LIMIT.
    def refine_diagnosis!(diagnosis, scenario, agent_run, tool_calls)
      return unless JUDGE_REFINED_FAULTS.include?(diagnosis["fault"])
      return unless judge_available?
      return if @judge_calls >= JUDGE_DIAGNOSIS_LIMIT

      @judge_calls += 1
      response = judge_class.prompt(
        message: refinement_prompt(diagnosis, scenario, agent_run, tool_calls),
        instructions: "You diagnose why an AI agent failed a task and recommend the fix. Respond ONLY with JSON."
      ).generate_now

      refined = parse_json_object(response.message&.content)
      return unless refined

      diagnosis["judge"] = refined.slice("recommendation", "suggested_tool", "instruction_change").compact
      diagnosis["recommendation"] = refined["recommendation"].to_s.strip if refined["recommendation"].present?
    rescue StandardError => e
      Rails.logger.error("[ScenarioEvaluationRunner] Diagnosis refinement error: #{e.class} - #{e.message}")
    end

    def refinement_prompt(diagnosis, scenario, agent_run, tool_calls)
      roster = tool_roster.map { |tool| "- #{tool[:name]}: #{tool[:description].truncate(160)}" }.join("\n")
      calls = tool_calls.map { |call| "- #{call['name']}#{call['error'] ? ' (errored)' : ''}: #{call['arguments'].to_json.truncate(200)}" }.join("\n")

      <<~PROMPT
        An AI agent failed one evaluation scenario. Recommend the fix.

        Agent instructions:
        ---
        #{@evaluation.agent.instructions.to_s.truncate(2_000).presence || '(no instructions configured)'}
        ---

        Tools available to the agent:
        #{roster.presence || '(none)'}

        Scenario (the user's message):
        #{scenario.prompt}
        #{scenario.expected_tools.any? ? "Expected tools: #{scenario.expected_tools.join(', ')}" : ''}
        #{scenario.notes.present? ? "Notes: #{scenario.notes.truncate(300)}" : ''}

        Tools the agent called:
        #{calls.presence || '(none)'}

        The agent's answer:
        ---
        #{agent_run.output.to_s.truncate(2_500).presence || '(empty)'}
        ---

        Detected fault: #{diagnosis['fault']} — #{diagnosis['summary']}

        Say what to change so this scenario passes. If the agent lacks a tool for the task, describe the
        tool to add. If the tools suffice, say what to change in the instructions.
        Respond ONLY with JSON:
        {"recommendation": "<two sentences at most>",
         "suggested_tool": {"name": "snake_case_name", "description": "what it returns"} or null,
         "instruction_change": "<the sentence to add or change>" or null}
      PROMPT
    end

    def parse_json_object(content)
      json = content.to_s[/\{.*\}/m]
      return nil unless json

      parsed = JSON.parse(json)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # --- aggregation ------------------------------------------------------

    def aggregate(results, specs)
      scores = {}
      by_cohort = results.group_by(&:cohort)
      comparing = specs.size > 1

      criterion_keys(results).each do |key|
        scores[key] =
          if comparing
            by_cohort.to_h { |label, cohort| [ label, stats_for(cohort.map { |result| result.scores[key] }) ] }
          else
            stats_for(results.map { |result| result.scores[key] })
          end
      end

      scores["_models"] = by_cohort.to_h { |label, cohort| [ label, model_summary(specs.find { |spec| spec.label == label }, cohort) ] }
      scores["_recommendations"] = recommendations_for(results)
      scores["_verdict"] = verdict_for(scores["_models"]) if comparing
      scores["_selection"] = results.first.evaluation_run.selection
      scores
    end

    def criterion_keys(results)
      keys = sample_criteria.map { |criterion| criterion["key"] }
      keys | results.flat_map { |result| result.scores.keys }
    end

    def stats_for(values)
      scored = values.compact
      return { "skipped" => true, "reason" => "No scorable answers" } if scored.empty?

      {
        "score" => (scored.sum / scored.size).round(3),
        "min" => scored.min.round(3),
        "max" => scored.max.round(3),
        "passed" => scored.count { |value| value >= PASS_THRESHOLD },
        "total" => scored.size
      }
    end

    def model_summary(spec, cohort)
      scored = cohort.filter_map(&:score)
      durations = cohort.filter_map(&:duration_ms)
      costs = cohort.filter_map(&:cost)

      {
        "provider" => spec&.provider,
        "model" => spec&.model,
        "scenarios" => cohort.size,
        "passed" => cohort.count(&:passed?),
        "errored" => cohort.count(&:errored?),
        "pass_rate" => cohort.any? ? (cohort.count(&:passed?) * 100.0 / cohort.size).round(1) : 0.0,
        "avg_score" => scored.any? ? (scored.sum / scored.size).round(3) : nil,
        "avg_duration_ms" => durations.any? ? (durations.sum.to_f / durations.size).round : nil,
        "input_tokens" => cohort.sum { |result| result.input_tokens.to_i },
        "output_tokens" => cohort.sum { |result| result.output_tokens.to_i },
        "cost" => costs.any? ? costs.sum.to_f.round(6) : nil,
        "faults" => cohort.filter_map(&:fault).tally
      }
    end

    # Faults grouped across scenarios and models, most frequent first, each
    # with the scenarios it hit and the fix it calls for.
    def recommendations_for(results)
      results.select(&:fault).group_by(&:fault).map do |fault, faulted|
        {
          "fault" => fault,
          "count" => faulted.size,
          "scenario_keys" => faulted.map { |result| result.scenario.key }.uniq,
          "models" => faulted.map(&:cohort).uniq,
          "recommendation" => faulted.map(&:recommendation).compact.tally.max_by(&:last)&.first,
          "suggested_tools" => faulted.filter_map { |result| result.diagnosis.dig("judge", "suggested_tool") }.uniq
        }
      end.sort_by { |entry| -entry["count"] }
    end

    # The model that passed the most scenarios (mean score, then cost, break
    # ties), with the judge's rationale when one is available.
    def verdict_for(models)
      ranked = models.sort_by do |_label, stats|
        [ -stats["pass_rate"].to_f, -stats["avg_score"].to_f, stats["cost"].to_f ]
      end
      winner, stats = ranked.first
      return nil unless winner

      rationale = "Passed #{stats['passed']} of #{stats['scenarios']} scenarios" \
        "#{stats['avg_score'] ? " with a mean score of #{stats['avg_score']}" : ''}" \
        "#{stats['cost'] ? " at an estimated $#{format('%.4f', stats['cost'])}" : ''}."
      judged = judge_verdict(models)

      {
        "winner" => judged&.dig("winner").presence || winner,
        "rationale" => judged&.dig("rationale").presence || rationale,
        "judge" => judged ? (@evaluation.judge_model.presence || judge_provider.to_s) : "pass rate"
      }
    end

    def judge_verdict(models)
      return nil unless judge_available?

      lines = models.map do |label, stats|
        faults = stats["faults"].map { |fault, count| "#{fault}×#{count}" }.join(", ")
        "#{label}: pass rate #{stats['pass_rate']}%, mean score #{stats['avg_score'] || 'n/a'}, " \
          "avg latency #{stats['avg_duration_ms'] || 'n/a'}ms, cost $#{stats['cost'] || 'n/a'}" \
          "#{faults.present? ? ", faults: #{faults}" : ''}"
      end

      response = judge_class.prompt(
        message: <<~PROMPT,
          An AI agent ran the same scenarios under several models. Its goals:
          ---
          #{@evaluation.agent.instructions.to_s.truncate(1_000).presence || '(no instructions configured)'}
          ---

          Results per model:
          #{lines.join("\n")}

          Which model best accomplishes the agent's goals, weighing task completion first and cost and
          latency second? Respond ONLY with JSON: {"winner": "<model>", "rationale": "<at most two sentences>"}
        PROMPT
        instructions: "You are an impartial evaluation judge comparing model cohorts. Respond ONLY with JSON."
      ).generate_now

      verdict = parse_json_object(response.message&.content)
      verdict if verdict && models.key?(verdict["winner"])
    rescue StandardError => e
      Rails.logger.error("[ScenarioEvaluationRunner] Verdict error: #{e.class} - #{e.message}")
      nil
    end
  end
end
