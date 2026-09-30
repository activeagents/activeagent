# frozen_string_literal: true

module ActionAgent
  # Runs an Evaluation against the agent's most recent persisted generations
  # (solid_agent's agent_generations).
  #
  # Rule-based criteria are scored deterministically from the recorded data.
  # The llm_judge criterion asks a judge model (through the activeagent gem)
  # to score each sample 0.0..1.0; it requires configured provider
  # credentials and is skipped — never faked — when none are available.
  class EvaluationRunnerService
    PASS_THRESHOLD = 0.7

    def self.call(evaluation)
      new(evaluation).call
    end

    # Returns the provider +owner+'s evaluation judge runs on (see
    # #judge_provider), or nil when no provider has credentials.
    def self.judge_provider_for(owner)
      new(nil, owner: owner).judge_provider
    end

    # +owner+ is whose provider credentials the judge uses: the evaluated
    # agent's owner unless given.
    def initialize(evaluation, owner: nil)
      @evaluation = evaluation
      @owner = owner
    end

    def call
      run = @evaluation.evaluation_runs.create!(status: :running)

      # judge_defined evaluations author their KPI criteria on first run.
      ensure_judge_defined_kpis! if @evaluation.judge_defined?

      sample_criteria, telemetry_criteria = @evaluation.criteria.partition do |criterion|
        !Evaluation::TELEMETRY_CRITERION_TYPES.include?(criterion["type"])
      end

      if @evaluation.compare_models.any?
        return score_comparison(run, sample_criteria, telemetry_criteria)
      end

      samples = sample_criteria.any? ? sample_generations : []
      if sample_criteria.any? && samples.empty?
        run.update!(
          status: :failed,
          error_message: "No generations to evaluate yet — run the agent first",
          completed_at: Time.current
        )
        return run
      end

      scores = {}
      per_sample_scores = Hash.new { |h, k| h[k] = [] }

      telemetry_criteria.each do |criterion|
        scores[criterion["key"]] = score_telemetry_criterion(criterion)
      end

      sample_criteria.each do |criterion|
        stats = criterion_stats(criterion, samples, per_sample_scores)
        scores[criterion["key"]] = stats
      end

      scores["_cohorts"] = cohort_summaries(samples, per_sample_scores) if samples.any?
      scores["_judge_usage"] = judge_usage if judge_usage

      run.update!(
        status: :complete,
        scores: scores,
        samples_evaluated: samples.size,
        samples_passed: passed_count(per_sample_scores),
        completed_at: Time.current
      )
      run
    rescue StandardError => e
      run&.update!(status: :failed, error_message: e.message, completed_at: Time.current)
      raise
    end

    # Returns the provider the judge runs on: the first of Anthropic, OpenAI
    # and OpenRouter the owner or the host's config has a key for, else Ollama
    # when the owner configured a host; nil when none. The judge runs
    # `judge_model` as that provider's own model id.
    def judge_provider
      @judge_provider ||=
        %i[anthropic openai openrouter].find do |name|
          owner_provider_options(name).any? || global_provider_token?(name)
        end || (:ollama if owner_provider_options(:ollama).any?)
    end

    private

    # Scores each sample-based criterion once per candidate model cohort and
    # asks the judge for a comparative verdict — "haiku vs qwen, judged".
    def score_comparison(run, sample_criteria, telemetry_criteria)
      cohorts = @evaluation.compare_models.index_with { |model| sample_generations(model: model) }
      active = cohorts.select { |_model, samples| samples.any? }

      if active.empty?
        run.update!(
          status: :failed,
          error_message: "No generations recorded under #{@evaluation.compare_models.join(', ')} — run the agent under those models first",
          completed_at: Time.current
        )
        return run
      end

      scores = {}
      per_model_sample_scores = {}

      telemetry_criteria.each do |criterion|
        scores[criterion["key"]] = score_telemetry_criterion(criterion)
      end

      sample_criteria.each do |criterion|
        scores[criterion["key"]] = active.each_with_object({}) do |(model, samples), by_model|
          per_sample = (per_model_sample_scores[model] ||= Hash.new { |h, k| h[k] = [] })
          by_model[model] = criterion_stats(criterion, samples, per_sample)
        end
      end

      # Models that were requested but have no recorded generations are
      # reported, not silently dropped.
      missing = cohorts.keys - active.keys
      scores["_missing_models"] = missing if missing.any?

      if active.size >= 2 && sample_criteria.any?
        verdict = comparison_verdict(active, sample_criteria, scores)
        scores["_verdict"] = verdict if verdict
      end

      scores["_cohorts"] = active.to_h do |model, samples|
        [ model, cohort_summary(samples, per_model_sample_scores[model] || {}) ]
      end
      scores["_judge_usage"] = judge_usage if judge_usage

      run.update!(
        status: :complete,
        scores: scores,
        samples_evaluated: active.values.sum(&:size),
        samples_passed: per_model_sample_scores.values.sum { |per_sample| passed_count(per_sample) },
        completed_at: Time.current
      )
      run
    end

    # Shared per-criterion scoring: returns the stats hash (or skipped) and
    # appends each sample's score into per_sample_scores for pass counting.
    def criterion_stats(criterion, samples, per_sample_scores)
      sample_scores = samples.map { |generation| score_sample(criterion, generation) }

      # nil means the criterion could not be scored (e.g. llm_judge without
      # provider credentials); it is reported as skipped, not zero.
      scored = sample_scores.compact
      return { "skipped" => true, "reason" => skip_reason(criterion) } if scored.empty?

      samples.each_with_index do |generation, index|
        per_sample_scores[generation.id] << sample_scores[index] if sample_scores[index]
      end

      {
        "score" => (scored.sum / scored.size).round(3),
        "min" => scored.min.round(3),
        "max" => scored.max.round(3),
        "passed" => scored.count { |s| s >= PASS_THRESHOLD },
        "total" => scored.size
      }
    end

    def passed_count(per_sample_scores)
      per_sample_scores.count do |_id, values|
        values.any? && values.all? { |s| s >= PASS_THRESHOLD }
      end
    end

    # --- Cohort summaries ------------------------------------------------------
    #
    # Stored under scores["_cohorts"], keyed by model: how many generations
    # were sampled under it, how many cleared every criterion, their latency
    # and token usage, and what those generations cost to serve. A comparison
    # run gets one entry per requested cohort that had generations; a plain
    # run one per model that happened to be among the sampled generations.
    # This is what lets the dashboard show a run as "5/12 passed" per model,
    # the way a scenario run's `_models` summaries do, without re-reading the
    # generations.
    #
    # The cost here is the agent's: what the sampled interactions cost to
    # operate. It is not what this run spent — scoring recorded generations
    # costs nothing until a judge is asked, and the judge's own spend is
    # recorded apart, under "_judge_usage" (see #judge_usage).

    def cohort_summaries(samples, per_sample_scores)
      samples
        .group_by { |generation| generation.model.presence || "unknown" }
        .transform_values { |group| cohort_summary(group, per_sample_scores) }
    end

    def cohort_summary(samples, per_sample_scores)
      durations_ms = samples.filter_map do |generation|
        seconds = generation.duration_seconds.to_f
        seconds * 1000 if seconds.positive?
      end
      providers = samples.filter_map { |generation| generation.provider.presence }
      input_tokens = samples.sum { |generation| generation.input_tokens.to_i }
      output_tokens = samples.sum { |generation| generation.output_tokens.to_i }
      costs = samples.filter_map do |generation|
        ModelPricing.estimate(model: generation.model, input_tokens: generation.input_tokens, output_tokens: generation.output_tokens)
      end

      {
        "samples" => samples.size,
        "passed" => passed_count(per_sample_scores.slice(*samples.map(&:id))),
        "provider" => providers.tally.max_by { |_provider, count| count }&.first,
        "avg_duration_ms" => durations_ms.any? ? (durations_ms.sum / durations_ms.size).round : nil,
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "cost" => costs.any? ? costs.sum.round(6) : nil
      }
    end

    # --- Judge usage -----------------------------------------------------------
    #
    # Every call the judge makes is metered here, apart from the agent's own
    # spend: scoring answers, recommending fixes, writing the verdict and,
    # for a judge_defined evaluation, authoring the KPIs. The agent's cost is
    # the operating figure — what serving these interactions costs — while
    # the judge's is the evaluation's own, offline, agent-to-agent overhead,
    # and a run that reported the two as one number would overstate the
    # first. Persisted as scores["_judge_usage"]:
    #
    #   { "calls", "input_tokens", "output_tokens", "cost", "model",
    #     "by_kind" => { "score" => n, "recommend" => n, "verdict" => n, "define" => n } }
    #
    # nil until the judge has been asked something, so a rules-only run
    # records no judge at all rather than a judge that cost nothing.

    def judge_usage
      return nil if @judge_usage.nil?

      @judge_usage.merge("cost" => @judge_usage["cost"]&.round(6))
    end

    # Asks the judge and meters the answer. `kind` is the call's purpose —
    # :score, :recommend, :verdict or :define — the same vocabulary
    # ActiveAgent::Evals::Judge hands a block that accepts `kind:`.
    def judge_generate(kind, message:, instructions:)
      response = judge_class.prompt(message: message, instructions: instructions).generate_now
      record_judge_call(kind, response)
      response
    end

    def record_judge_call(kind, response)
      usage = response.respond_to?(:usage) ? response.usage : nil
      input_tokens = usage.respond_to?(:input_tokens) ? usage.input_tokens.to_i : 0
      output_tokens = usage.respond_to?(:output_tokens) ? usage.output_tokens.to_i : 0
      model = (response.respond_to?(:model) && response.model.presence) || @evaluation.judge_model.presence
      cost = ModelPricing.estimate(model: model, input_tokens: input_tokens, output_tokens: output_tokens)

      @judge_usage ||= { "calls" => 0, "input_tokens" => 0, "output_tokens" => 0, "cost" => nil, "model" => nil, "by_kind" => {} }
      @judge_usage["calls"] += 1
      @judge_usage["input_tokens"] += input_tokens
      @judge_usage["output_tokens"] += output_tokens
      @judge_usage["cost"] = (@judge_usage["cost"] || 0.0) + cost if cost
      @judge_usage["model"] ||= model
      @judge_usage["by_kind"][kind.to_s] = @judge_usage["by_kind"].fetch(kind.to_s, 0) + 1
    end

    def sample_generations(model: nil)
      scope = @evaluation.agent.generations
      scope = scope.where(model: model) if model
      scope.order(created_at: :desc).limit(@evaluation.sample_size).to_a
    end

    # --- Telemetry criteria ---------------------------------------------------
    #
    # Scored from the agent's telemetry traces over a config window — an
    # aggregate per criterion, not per sample. min/max/passed/total mirror the
    # aggregate so results render like sample-based criteria in the UI.

    def score_telemetry_criterion(criterion)
      config = criterion["config"] || {}
      window_hours = config.fetch("window_hours", 168).to_i.clamp(1, 720)

      # Multi-tenant installs need an owner to scope traces to; a
      # single-tenant one reads every trace it has.
      if ActionAgent.multi_tenant? && owner.nil?
        return { "skipped" => true, "reason" => "No tenant for telemetry lookup" }
      end

      traces = telemetry_traces(window_hours)
      total = traces.count
      if total.zero?
        return {
          "skipped" => true,
          "reason" => "No telemetry traces for #{telemetry_source} in the last #{window_hours}h"
        }
      end

      score, observed = case criterion["type"]
      when "trace_error_rate"
        max_rate = config.fetch("max_error_rate", 5.0).to_f
        errors = traces.with_errors.count
        rate = errors * 100.0 / total
        value = if rate <= max_rate
          1.0
        elsif rate.zero?
          1.0
        else
          max_rate.positive? ? (max_rate / rate).clamp(0.0, 1.0) : 0.0
        end
        [ value, { "error_rate" => rate.round(2), "errors" => errors, "max_error_rate" => max_rate } ]
      when "trace_latency"
        budget = config.fetch("max_avg_ms", 5_000).to_f
        avg = traces.average(:total_duration_ms).to_f
        value = avg.zero? || avg <= budget ? 1.0 : (budget / avg).clamp(0.0, 1.0)
        [ value, { "avg_duration_ms" => avg.round, "max_avg_ms" => budget } ]
      end

      {
        "score" => score.round(3),
        "min" => score.round(3),
        "max" => score.round(3),
        "passed" => score >= PASS_THRESHOLD ? 1 : 0,
        "total" => 1,
        "source" => "telemetry",
        "window_hours" => window_hours,
        "traces" => total,
        "observed" => observed
      }
    end

    def telemetry_traces(window_hours)
      @evaluation.agent
        .telemetry_traces(ActionAgent.trace_model.for_account(ActionAgent.tenant_for(owner)))
        .for_date_range(window_hours.hours.ago, Time.current)
    end

    # What a skip reason says was looked for: the observed agent itself, or
    # the class any other agent's traces are reported under.
    def telemetry_source
      agent = @evaluation.agent
      agent.observed? ? agent.name : agent.telemetry_agent_class
    end

    # Returns 0.0..1.0, or nil when the criterion cannot be scored.
    def score_sample(criterion, generation)
      config = criterion["config"] || {}

      case criterion["type"]
      when "response_present"
        generation.content.present? ? 1.0 : 0.0
      when "min_length"
        min = config.fetch("chars", 40).to_i
        length = generation.content.to_s.length
        [ length.to_f / min, 1.0 ].min
      when "max_latency_ms"
        budget = config.fetch("ms", 5_000).to_f
        duration_ms = generation.duration_seconds.to_f * 1000
        return 1.0 if duration_ms.zero? # duration not recorded
        duration_ms <= budget ? 1.0 : [ budget / duration_ms, 1.0 ].min
      when "token_budget"
        budget = config.fetch("output_tokens", 1_000).to_f
        tokens = generation.output_tokens.to_f
        tokens <= budget ? 1.0 : [ budget / tokens, 1.0 ].min
      when "contains"
        matches_pattern?(generation.content, config) ? 1.0 : 0.0
      when "not_contains"
        matches_pattern?(generation.content, config) ? 0.0 : 1.0
      when "llm_judge"
        llm_judge_score(criterion, generation)
      end
    end

    def matches_pattern?(content, config)
      pattern = config["pattern"].to_s
      return false if pattern.blank?

      content.to_s.match?(Regexp.new(pattern, Regexp::IGNORECASE))
    rescue RegexpError
      content.to_s.downcase.include?(pattern.downcase)
    end

    # --- Judge-defined KPIs --------------------------------------------------
    #
    # The judge reads the agent's goals (its instructions) plus sample
    # interactions and authors 3-6 measurable KPIs, persisted as llm_judge
    # criteria with provenance. Stable persisted KPIs are what make scores
    # comparable across evaluation runs and across models.

    KPI_LIMIT = 6

    def ensure_judge_defined_kpis!
      return if @evaluation.criteria.any? { |c| c["type"] == "llm_judge" && c["defined_by"].present? }

      unless judge_available?
        raise "Judge-defined KPIs need provider credentials (add a provider API key in Settings)"
      end

      response = judge_generate(
        :define,
        message: kpi_definition_prompt,
        instructions: "You define measurable evaluation KPIs for AI agents. Respond ONLY with JSON."
      )

      kpis = parse_kpis(response.message&.content)
      raise "Judge returned no usable KPIs — try again or add criteria manually" if kpis.empty?

      judge_label = @evaluation.judge_model.presence || judge_provider.to_s
      defined_at = Time.current.iso8601
      kpi_criteria = kpis.first(KPI_LIMIT).map do |kpi|
        prompt_text = [
          kpi["description"].to_s,
          kpi["scoring_guidance"].presence && "Scoring guidance: #{kpi['scoring_guidance']}"
        ].compact.join("\n")
        {
          "key" => kpi["key"].to_s.parameterize(separator: "_").presence || kpi["description"].to_s.parameterize(separator: "_").first(40),
          "type" => "llm_judge",
          "defined_by" => judge_label,
          "defined_at" => defined_at,
          "config" => { "prompt" => prompt_text, "description" => kpi["description"] }
        }
      end

      @evaluation.update!(
        criteria: @evaluation.criteria + kpi_criteria,
        config: @evaluation.config.merge(
          "kpi_provenance" => { "judge" => judge_label, "defined_at" => defined_at }
        )
      )
    end

    def kpi_definition_prompt
      samples = @evaluation.agent.agent_runs.successful.recent.limit(5).map do |run|
        "User: #{run.input_prompt.to_s.truncate(400)}\nAgent: #{run.output.to_s.truncate(600)}"
      end

      <<~PROMPT
        Define evaluation KPIs for this AI agent.

        The agent's system instructions (its goals):
        ---
        #{@evaluation.agent.instructions.to_s.truncate(2_000).presence || '(no instructions configured)'}
        ---

        Sample interactions:
        ---
        #{samples.join("\n---\n").presence || '(no interactions recorded yet)'}
        ---

        Define 3-#{KPI_LIMIT} measurable KPIs that capture whether the agent accomplishes its goals.
        Each KPI must be scorable from a single interaction's output on a 0.0-1.0 scale.
        Respond ONLY with JSON:
        {"kpis": [{"key": "snake_case_id", "description": "what to measure", "scoring_guidance": "how to assign 0.0-1.0"}]}
      PROMPT
    end

    def parse_kpis(content)
      json = content.to_s[/\{.*\}/m]
      return [] unless json

      Array(JSON.parse(json)["kpis"]).select { |kpi| kpi.is_a?(Hash) && kpi["description"].present? }
    rescue JSON::ParserError
      []
    end

    # Comparative verdict across model cohorts: the judge sees each model's
    # per-KPI mean scores and declares which best accomplishes the goals.
    def comparison_verdict(active_cohorts, sample_criteria, scores)
      return nil unless judge_available?

      lines = sample_criteria.map do |criterion|
        key = criterion["key"]
        cells = active_cohorts.keys.map do |model|
          stats = scores.dig(key, model)
          value = stats && stats["score"]
          "#{model}=#{value.nil? ? 'skipped' : value} (#{stats&.dig('total') || 0} samples)"
        end
        "#{key}: #{cells.join(', ')}"
      end

      response = judge_generate(
        :verdict,
        message: <<~PROMPT,
          An AI agent was evaluated under multiple models. Its goals:
          ---
          #{@evaluation.agent.instructions.to_s.truncate(1_000).presence || '(no instructions configured)'}
          ---

          Per-KPI mean scores (0.0-1.0) per model:
          #{lines.join("\n")}

          Which model best accomplishes the agent's goals?
          Respond ONLY with JSON: {"winner": "<model>", "rationale": "<at most two sentences>"}
        PROMPT
        instructions: "You are an impartial evaluation judge comparing model cohorts. Respond ONLY with JSON."
      )

      json = response.message&.content.to_s[/\{.*\}/m]
      verdict = json ? JSON.parse(json) : nil
      return nil unless verdict.is_a?(Hash) && verdict["winner"].present?

      {
        "winner" => verdict["winner"],
        "rationale" => verdict["rationale"].to_s,
        "judge" => @evaluation.judge_model.presence || judge_provider.to_s
      }
    rescue StandardError => e
      Rails.logger.error("[EvaluationRunnerService] Verdict error: #{e.class} - #{e.message}")
      nil
    end

    # --- LLM judge -----------------------------------------------------------

    def llm_judge_score(criterion, generation)
      return nil unless judge_available?
      return nil if generation.content.blank?

      response = judge_generate(
        :score,
        message: judge_prompt(criterion, generation),
        instructions: "You are an impartial evaluation judge. Respond ONLY with JSON: {\"score\": <float between 0.0 and 1.0>}"
      )

      parse_judge_score(response.message&.content)
    rescue StandardError => e
      Rails.logger.error("[EvaluationRunnerService] Judge error: #{e.class} - #{e.message}")
      nil
    end

    def judge_prompt(criterion, generation)
      <<~PROMPT
        Criterion: #{criterion.dig('config', 'prompt').presence || criterion['key'].to_s.humanize}

        Agent output to evaluate:
        ---
        #{generation.content.to_s.truncate(4_000)}
        ---

        Score the output against the criterion from 0.0 (fails completely) to 1.0 (fully satisfies).
        Respond only with JSON: {"score": <float>}
      PROMPT
    end

    # The judge answers with a JSON number, so "9e-2" is 0.09; a digit-only
    # regex read that as 9 and clamped a near-zero score to a perfect 1.0.
    # Mirrors ActiveAgent::Evals::Judge#parse_score, which is private there
    # and may be the older, unfixed one when the host pins activeagent 1.4.0.
    def parse_judge_score(content)
      json = content.to_s[/\{.*\}/m]
      return nil unless json

      parsed = JSON.parse(json)
      value = parsed.is_a?(Hash) ? parsed["score"] : nil
      return nil unless value.is_a?(Numeric) && value.finite?

      value.to_f.clamp(0.0, 1.0)
    rescue JSON::ParserError
      nil
    end

    # The judge needs real provider credentials; scoring with the mock
    # provider would fabricate results.
    def judge_available?
      judge_provider.present?
    end

    def global_provider_token?(name)
      config = ActiveAgent.configuration[name]
      config.respond_to?(:[]) && config[:access_token].present?
    end

    # The evaluated agent owner's credential for +name+ (Settings ->
    # Provider API Keys, or whatever the host app resolves); preferred over
    # the host's config/active_agent.yml credentials for the judge.
    def owner_provider_options(name)
      @owner_provider_options ||= {}
      @owner_provider_options[name.to_s] ||= begin
        from_host = ActionAgent.provider_credentials(owner, name.to_s)
        from_host.presence || ProviderKey.for_owner(owner).find_by(provider: name.to_s)&.generation_options || {}
      end
    end

    def owner
      @owner ||= @evaluation&.agent&.owner
    end

    def judge_class
      @judge_class ||= begin
        provider = judge_provider
        model = @evaluation.judge_model.presence
        options = {}
        options[:model] = model if model
        options.merge!(owner_provider_options(provider))

        Class.new(ActiveAgent::Base) do
          define_singleton_method(:name) { "EvaluationJudgeAgent" }
          generate_with provider, **options
        end
      end
    end

    def skip_reason(criterion)
      if criterion["type"] == "llm_judge"
        "LLM judge requires provider credentials (add a provider API key in Settings or set ANTHROPIC_API_KEY / OPENAI_API_KEY)"
      else
        "No scorable samples"
      end
    end
  end
end
