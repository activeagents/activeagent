# frozen_string_literal: true

module ActiveAgent
  module Evals
    # Replays every scenario under every candidate model, scores and diagnoses
    # each answer, and returns a Report.
    #
    # The one thing the runner does not know is how to talk to your agent;
    # `replay` is a callable `(scenario, model_spec) → Replay` (a Hash with the
    # same keys is accepted, and an exception becomes an errored Replay). A
    # scenario passes when its replay completed, met its expectations, and both
    # its mean score and the mean of its judge grades (task completion, or the
    # configured llm_judge criteria) reached `threshold`;
    # anything else carries exactly one fault
    # and a recommendation from Diagnosis, refined by the `judge` for the
    # faults in `refine_faults` (up to `judge_limit` calls per run).
    #
    #   Runner.new(
    #     scenarios: suite.scenarios(groups: %w[history]),
    #     models: ModelSpec.parse_all(%w[gpt-5-mini claude-haiku-4-5], default_provider: "openai"),
    #     criteria: [{ "key" => "response_present", "type" => "response_present" }],
    #     available_tools: { "lookup_order" => "Find an order by number" },
    #     instructions: agent.instructions,
    #     judge: Judge.new(label: "claude-opus-5") { |instructions:, prompt:| ... },
    #     replay: ->(scenario, spec) { ... },
    #     on_result: ->(result) { persist(result) }
    #   ).call
    class Runner
      # Faults where a judge can add something the evidence alone cannot: what
      # tool to add, or how to change the instructions.
      DEFAULT_REFINE_FAULTS = %w[missing_capability expected_tool_not_called ungrounded_answer low_quality missing_content].freeze
      DEFAULT_JUDGE_LIMIT = 25

      attr_reader :scenarios, :models, :criteria, :judge, :threshold, :pass_thresholds, :judge_failed_expectations

      # @param scenarios [Array<Scenario>]
      # @param models [Array<ModelSpec>]
      # @param replay [#call] `(scenario, model_spec) → Replay`
      # @param criteria [Array<Hash>] Scorer criteria applied to every replay
      # @param judge [Judge, nil]
      # @param judge_task [Boolean] with a judge and no llm_judge criterion, also
      #   score task completion (`Judge#score_task`) as the `task_completion` criterion
      # @param available_tools [Hash{String=>String}, Array<String>] the agent's tool roster
      # @param instructions [String, nil] the agent's instructions, for the judge
      # @param agent_name [String] how recommendations refer to the agent
      # @param threshold [Float, nil] the score an answer must reach to pass;
      #   an explicit value wins over the `pass_thresholds` bar, and without
      #   either it is PASS_THRESHOLD
      # @param pass_thresholds [PassThresholds, nil] the bars the suite
      #   declared (Suite#pass_thresholds): its threshold applies when none
      #   is given here, and the Report gates each group by it (Report#gates)
      # @param on_result [#call, nil] called with each Result as it lands
      # @param around_evaluation [#call, nil] called with (scenario, spec) and a
      #   block that returns the Result. Establishes context for replay, scoring
      #   and recommendations; must return the block's result. Wrapper errors
      #   propagate to the caller. Applies to #call, not direct #evaluate calls.
      # @param require_judge_scores [Boolean] fail an otherwise passing result
      #   when a requested task/LLM grade is unavailable, rather than falling
      #   back to rule scores. Does not require a judge for rules-only runs.
      # @param release [Hash, nil] the release of the agent under evaluation,
      #   `{ "digest", "revision", "label" }`, carried onto the Report so a
      #   published run names the code it scored (see Report.new)
      # @param refine_gate [#call, nil] asked before each recommendation call,
      #   after `judge_limit`; false skips it. A caller that scores each
      #   scenario in its own Runner (a background job per scenario) shares one
      #   run-wide limit this way, since `judge_limit` counts per instance.
      # @param judge_failed_expectations [Boolean] whether the judge grades a
      #   replay that missed one of its scenario's expectations (an expected
      #   tool not called, forbidden or missing content, a failed tool call).
      #   false skips its task grade, its llm_judge criteria and its judged
      #   recommendation, since it fails whatever the judge says, and the
      #   calls saved do not count against `judge_limit`. The default grades
      #   every answered replay.
      def initialize(scenarios:, models:, replay:, criteria: [], judge: nil, judge_task: true, available_tools: {},
                     instructions: nil, agent_name: "The agent", threshold: nil, pass_thresholds: nil,
                     refine_faults: DEFAULT_REFINE_FAULTS, judge_limit: DEFAULT_JUDGE_LIMIT, on_result: nil,
                     around_evaluation: nil, require_judge_scores: false, metadata: {}, release: nil, refine_gate: nil,
                     judge_failed_expectations: true)
        @scenarios = scenarios
        @models = models
        @replay = replay
        @criteria = criteria
        @judge = judge
        @judge_task = judge_task
        @available_tools = normalize_tools(available_tools)
        @instructions = instructions
        @agent_name = agent_name
        @threshold = threshold || pass_thresholds&.threshold || PASS_THRESHOLD
        @pass_thresholds = pass_thresholds
        @refine_faults = refine_faults
        @judge_limit = judge_limit
        @on_result = on_result
        @around_evaluation = around_evaluation
        @require_judge_scores = require_judge_scores
        @metadata = metadata
        @release = release
        @refine_gate = refine_gate
        @judge_failed_expectations = judge_failed_expectations
        @judge_calls = 0
        @scorer = Scorer.new(criteria: criteria, judge: judge, judge_failed_expectations: judge_failed_expectations)
      end

      def call
        results = @scenarios.flat_map do |scenario|
          @models.map do |spec|
            evaluate_with_context(scenario, spec).tap { |result| @on_result&.call(result) }
          end
        end

        Report.new(results: results, models: @models, judge: @judge, instructions: @instructions,
                   threshold: @threshold, metadata: @metadata, release: @release, pass_thresholds: @pass_thresholds)
      end

      # Scores and diagnoses one replay. Public so a caller that has already run
      # the agent (a background job per scenario, say) can score without the loop.
      def evaluate(scenario, spec, replay = nil)
        replay ||= run_replay(scenario, spec)
        scores = @scorer.score(scenario, replay)
        if judge_task? && replay.answer.present? && judge_answer?(scores)
          scores["task_completion"] = @judge.score_task(scenario: scenario, answer: replay.answer)
        end
        score = Scorer.mean(scores)

        diagnosis = Diagnosis.call(scenario: scenario, replay: replay, scores: scores, score: score,
                                   available_tools: @available_tools.keys, threshold: @threshold, agent_name: @agent_name,
                                   judge_keys: llm_judge_keys)
        diagnosis ||= unavailable_judge_diagnosis(scores)
        diagnosis_hash = diagnosis&.to_h
        refine!(diagnosis_hash, scenario, replay, diagnosis, scores) if diagnosis_hash

        Result.new(
          scenario: scenario,
          spec: spec,
          replay: replay,
          scores: scores,
          score: score,
          status: replay.errored? ? "errored" : (diagnosis ? "failed" : "passed"),
          diagnosis: diagnosis_hash
        )
      end

      private

      def evaluate_with_context(scenario, spec)
        return evaluate(scenario, spec) unless @around_evaluation

        result = @around_evaluation.call(scenario, spec) { evaluate(scenario, spec) }
        # A wrapper written the natural way — do something, yield, do something
        # after — returns that last value rather than the Result. Left alone it
        # reaches on_result and the Report, and fails somewhere far from the
        # wrapper that caused it. Name the wrapper here instead.
        unless result.is_a?(Result)
          raise ArgumentError, "around_evaluation must return the Result its block yields, got #{result.class}"
        end

        result
      end

      def judge_task?
        @judge && @judge_task && @criteria.none? { |criterion| criterion.to_h.stringify_keys["type"] == "llm_judge" }
      end

      # Whether the judge is asked about a replay with these scores: always by
      # default, or only when it met every expectation of its scenario. A
      # replay that did not already carries one of the faults Diagnosis
      # assigns ahead of low_quality (tool_error, missing_capability,
      # expected_tool_not_called, ungrounded_answer, forbidden_content or
      # missing_content), so its status is failed whatever the judge would say.
      def judge_answer?(scores)
        @judge_failed_expectations || Scorer.expectations_met?(scores)
      end

      # The keys in `scores` a judge graded, so a low grade is not averaged
      # away against rule checks.
      def llm_judge_keys
        @llm_judge_keys ||= @criteria.filter_map do |criterion|
          value = criterion.to_h.stringify_keys
          value["key"] if value["type"] == "llm_judge"
        end
      end

      def unavailable_judge_diagnosis(scores)
        return unless @require_judge_scores

        keys = llm_judge_keys.dup
        keys << "task_completion" if judge_task?
        missing = keys.select { |key| scores[key].nil? }
        return if missing.empty?

        Diagnosis::Result.new(
          fault: "judge_unavailable",
          summary: "The evaluation judge did not return a usable score for #{missing.join(', ')}.",
          recommendation: "Check the judge's credentials, model availability and JSON response, then re-run this evaluation. " \
                          "The available rule scores do not establish answer quality.",
          evidence: { "unscored_criteria" => missing }
        )
      end

      # Whatever the callable raises becomes an errored Replay, so one model
      # rejecting a parameter fails its scenario rather than the whole run.
      # A return value that is neither a Replay nor a Hash is the caller's
      # bug and raises.
      def run_replay(scenario, spec)
        value =
          begin
            @replay.call(scenario, spec)
          rescue StandardError => e
            return Replay.failed(e)
          end

        case value
        when Replay then value
        when Hash then Replay.new(**value.to_h.symbolize_keys)
        else raise ArgumentError, "replay must return an ActiveAgent::Evals::Replay or a Hash, got #{value.class}"
        end
      end

      def refine!(diagnosis, scenario, replay, result, scores)
        return unless @judge && @refine_faults.include?(result.fault)
        return unless judge_answer?(scores)
        return if @judge_calls >= @judge_limit
        return if @refine_gate && !@refine_gate.call

        @judge_calls += 1
        refined = @judge.recommend(scenario: scenario, replay: replay, diagnosis: result,
                                   available_tools: @available_tools, instructions: @instructions)
        return unless refined

        diagnosis["judge"] = refined
        diagnosis["recommendation"] = refined["recommendation"].to_s.strip if refined["recommendation"].present?
      end

      def normalize_tools(tools)
        case tools
        when Hash then tools.to_h { |name, description| [ name.to_s, description.to_s ] }
        else Array(tools).to_h { |tool| tool.respond_to?(:name) ? [ tool.name.to_s, (tool.respond_to?(:description) ? tool.description.to_s : "") ] : [ tool.to_s, "" ] }
        end
      end
    end
  end
end
