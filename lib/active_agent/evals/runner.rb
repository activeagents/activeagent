# frozen_string_literal: true

module ActiveAgent
  module Evals
    # Replays every scenario under every candidate model, scores and diagnoses
    # each answer, and returns a Report.
    #
    # The one thing the runner does not know is how to talk to your agent;
    # `replay` is a callable `(scenario, model_spec) → Replay` (a Hash with the
    # same keys is accepted, and an exception becomes an errored Replay). A
    # scenario passes when its replay completed, met its expectations, and its
    # mean score reached `threshold`; anything else carries exactly one fault
    # and a recommendation from Diagnosis, refined by the `judge` for the
    # faults in `refine_faults` (up to `judge_limit` calls per run).
    #
    #   Runner.new(
    #     scenarios: suite.scenarios(groups: %w[blame]),
    #     models: ModelSpec.parse_all(%w[gpt-5-mini claude-haiku-4-5], default_provider: "openai"),
    #     criteria: [{ "key" => "response_present", "type" => "response_present" }],
    #     available_tools: { "find_records" => "Look up records" },
    #     instructions: agent.instructions,
    #     judge: Judge.new(label: "claude-opus-5") { |instructions:, prompt:| ... },
    #     replay: ->(scenario, spec) { ... },
    #     on_result: ->(result) { persist(result) }
    #   ).call
    class Runner
      # Faults where a judge can add something the evidence alone cannot: what
      # tool to add, or how to change the instructions.
      DEFAULT_REFINE_FAULTS = %w[missing_capability expected_tool_not_called low_quality missing_content].freeze
      DEFAULT_JUDGE_LIMIT = 25

      attr_reader :scenarios, :models, :criteria, :judge, :threshold

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
      # @param on_result [#call, nil] called with each Result as it lands
      def initialize(scenarios:, models:, replay:, criteria: [], judge: nil, judge_task: true, available_tools: {},
                     instructions: nil, agent_name: "The agent", threshold: PASS_THRESHOLD,
                     refine_faults: DEFAULT_REFINE_FAULTS, judge_limit: DEFAULT_JUDGE_LIMIT, on_result: nil, metadata: {})
        @scenarios = scenarios
        @models = models
        @replay = replay
        @criteria = criteria
        @judge = judge
        @judge_task = judge_task
        @available_tools = normalize_tools(available_tools)
        @instructions = instructions
        @agent_name = agent_name
        @threshold = threshold
        @refine_faults = refine_faults
        @judge_limit = judge_limit
        @on_result = on_result
        @metadata = metadata
        @judge_calls = 0
        @scorer = Scorer.new(criteria: criteria, judge: judge)
      end

      def call
        results = @scenarios.flat_map do |scenario|
          @models.map do |spec|
            evaluate(scenario, spec).tap { |result| @on_result&.call(result) }
          end
        end

        Report.new(results: results, models: @models, judge: @judge, instructions: @instructions,
                   threshold: @threshold, metadata: @metadata)
      end

      # Scores and diagnoses one replay. Public so a caller that has already run
      # the agent (a background job per scenario, say) can score without the loop.
      def evaluate(scenario, spec, replay = nil)
        replay ||= run_replay(scenario, spec)
        scores = @scorer.score(scenario, replay)
        if judge_task? && replay.answer.present?
          scores["task_completion"] = @judge.score_task(scenario: scenario, answer: replay.answer)
        end
        score = Scorer.mean(scores)

        diagnosis = Diagnosis.call(scenario: scenario, replay: replay, scores: scores, score: score,
                                   available_tools: @available_tools.keys, threshold: @threshold, agent_name: @agent_name)
        diagnosis_hash = diagnosis&.to_h
        refine!(diagnosis_hash, scenario, replay, diagnosis) if diagnosis_hash

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

      def judge_task?
        @judge && @judge_task && @criteria.none? { |criterion| criterion.to_h.stringify_keys["type"] == "llm_judge" }
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

      def refine!(diagnosis, scenario, replay, result)
        return unless @judge && @refine_faults.include?(result.fault)
        return if @judge_calls >= @judge_limit

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
