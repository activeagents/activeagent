# frozen_string_literal: true

module ActiveAgent
  module Dashboard
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

      def initialize(evaluation)
        @evaluation = evaluation
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

      def sample_generations(model: nil)
        scope = AgentGeneration
          .joins(:agent_context)
          .where(AgentContext.table_name => { contextable: @evaluation.agent })
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
        if ActiveAgent::Dashboard.multi_tenant? && owner.nil?
          return { "skipped" => true, "reason" => "No tenant for telemetry lookup" }
        end

        traces = telemetry_traces(window_hours)
        total = traces.count
        if total.zero?
          return {
            "skipped" => true,
            "reason" => "No telemetry traces for #{@evaluation.agent.telemetry_agent_class} in the last #{window_hours}h"
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
        ActiveAgent::Dashboard.trace_model
          .for_account(ActiveAgent::Dashboard.tenant_for(owner))
          .for_agent(@evaluation.agent.telemetry_agent_class)
          .for_date_range(window_hours.hours.ago, Time.current)
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

        response = judge_class.prompt(
          message: kpi_definition_prompt,
          instructions: "You define measurable evaluation KPIs for AI agents. Respond ONLY with JSON."
        ).generate_now

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

        response = judge_class.prompt(
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
        ).generate_now

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

        response = judge_class.prompt(
          message: judge_prompt(criterion, generation),
          instructions: "You are an impartial evaluation judge. Respond ONLY with JSON: {\"score\": <float between 0.0 and 1.0>}"
        ).generate_now

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

      def parse_judge_score(content)
        match = content.to_s.match(/"score"\s*:\s*(\d+(?:\.\d+)?)/)
        return nil unless match

        match[1].to_f.clamp(0.0, 1.0)
      end

      # The judge needs real provider credentials; scoring with the mock
      # provider would fabricate results.
      def judge_available?
        judge_provider.present?
      end

      def judge_provider
        @judge_provider ||=
          %i[anthropic openai openrouter].find do |name|
            owner_provider_options(name).any? || global_provider_token?(name)
          end || (:ollama if owner_provider_options(:ollama).any?)
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
          from_host = ActiveAgent::Dashboard.provider_credentials(owner, name.to_s)
          from_host.presence || ProviderKey.for_owner(owner).find_by(provider: name.to_s)&.generation_options || {}
        end
      end

      def owner
        @owner ||= @evaluation.agent.owner
      end

      def judge_class
        provider = judge_provider
        model = @evaluation.judge_model.presence
        options = {}
        options[:model] = model if model
        options.merge!(owner_provider_options(provider))

        @judge_class ||= Class.new(ActiveAgent::Base) do
          define_singleton_method(:name) { "EvaluationJudgeAgent" }
          generate_with provider, **options
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
end
