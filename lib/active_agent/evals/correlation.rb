# frozen_string_literal: true

require "securerandom"
require "active_support/isolated_execution_state"

module ActiveAgent
  module Evals
    # Used to tie the traces an evaluation produces back to the run and the
    # result that caused them, so a report row links to the exact conversation
    # behind it.
    #
    # A run mints a `run_id`, each evaluation mints a `result_id`, and both ride
    # every trace opened inside them as `eval.`-prefixed attributes. The trace
    # ids travel the other way: a replay's trace id lands on
    # `result.replay.metadata["trace_id"]`, and every judge call made while
    # scoring that result appends to its `"judge_trace_ids"`. The verdict — a
    # judge call made outside any evaluation — appends to the run metadata
    # instead, which is the same Hash a Report carries as its `metadata`.
    #
    # A tracer is `(name, action:, attributes:, on_trace:) { ... }`: it opens a
    # trace named for the agent, and calls `on_trace` with something answering
    # to `#trace_id` once the trace is known.
    #
    #   correlation = ActiveAgent::Evals::Correlation.new(
    #     agent_name: "SupportAgent",
    #     judge_name: "SupportAgentJudge",
    #     tracer: ->(name, action:, attributes:, on_trace:, &block) {
    #       MyTelemetry.with_agent(name, action: action, attributes: attributes,
    #                              on_trace: on_trace, synchronous: true, &block)
    #     }
    #   )
    #
    #   correlation.with_run("suite" => "support") do |metadata|
    #     Runner.new(
    #       scenarios: scenarios, models: models, metadata: metadata,
    #       replay: ->(scenario, spec) { correlation.replay { agent.run(scenario.prompt) } },
    #       judge: Judge.new(label: "judge-model") { |instructions:, prompt:|
    #         correlation.judge("score") { chat.with_instructions(instructions).ask(prompt).content }
    #       },
    #       around_evaluation: correlation
    #     ).call
    #   end
    #
    # Without a tracer the correlation still mints ids and merges metadata. The
    # blocks run untraced.
    class Correlation
      STATE_KEY = :active_agent_evals_correlation

      # DEFAULT_TRACE_KEYS names the correlation metadata that rides a trace as
      # `eval.`-prefixed attributes. Anything else a caller puts in the run
      # metadata (a tenant, a role) stays on the report but off the traces.
      DEFAULT_TRACE_KEYS = %w[run_id result_id suite scenario_key model_label model provider].freeze

      attr_reader :agent_name, :judge_name, :trace_keys

      # @param agent_name [String] the trace name for the agent under evaluation
      # @param judge_name [String] the trace name for judge traffic, kept distinct
      #   so grading calls do not read as the agent's own traffic
      # @param tracer [#call, nil] `(name, action:, attributes:, on_trace:) { ... }`;
      #   nil runs every block untraced
      # @param replay_action [String] the action name recorded for a replay trace
      # @param trace_keys [Array<String>] which correlation keys become attributes
      def initialize(agent_name:, judge_name: "#{agent_name}Judge", tracer: nil, replay_action: "eval",
                     trace_keys: DEFAULT_TRACE_KEYS)
        @agent_name = agent_name
        @judge_name = judge_name
        @tracer = tracer
        @replay_action = replay_action
        @trace_keys = trace_keys.map(&:to_s)
      end

      # Opens a run. Mints `run_id` unless `metadata` carries one, and yields the
      # metadata hash the traces will be correlated against — pass that same hash
      # to `Runner.new(metadata:)` so the Report carries the run's identity and
      # collects the verdict's trace id.
      #
      # The hash yielded is the caller's own, mutated in place, so a run
      # reopened around a later verdict accumulates onto the metadata a Report
      # already carries.
      #
      # @param metadata [Hash] opaque run metadata. A non-Hash is coerced with
      #   `#to_h`, and non-String keys are stringified.
      # @yieldparam metadata [Hash]
      def with_run(metadata = {})
        run = metadata.is_a?(Hash) ? metadata : metadata.to_h
        run.transform_keys!(&:to_s) unless run.keys.all?(String)
        run["run_id"] ||= SecureRandom.uuid
        with_context({ run: run, result: nil }) { yield run }
      end

      # Wraps one evaluation, in the shape `Runner.new(around_evaluation:)` calls:
      # `(scenario, spec) { ... } → Result`. Mints a `result_id`, merges the
      # correlation onto the Result's replay metadata, and returns the Result.
      def around_evaluation(scenario, spec)
        result_metadata = {
          "run_id" => run_metadata["run_id"],
          "result_id" => SecureRandom.uuid,
          "scenario_key" => scenario.key,
          "model_label" => spec.label,
          "model" => spec.model,
          "provider" => spec.provider
        }.compact

        with_context(run: run_metadata, result: result_metadata) do
          yield.tap { |result| result.replay.metadata.merge!(result_metadata) }
        end
      end

      # Delegates to `around_evaluation`, so the object satisfies
      # `Runner.new(around_evaluation:)` directly.
      def call(scenario, spec, &)
        around_evaluation(scenario, spec, &)
      end

      # Traces one replay of the agent under evaluation. The trace id lands on
      # the current result's metadata, so a report row links to the conversation.
      def replay(action = @replay_action, &)
        trace(@agent_name, action, judge: false, &)
      end

      # Traces one judge call. Appends to the current result's `judge_trace_ids`,
      # or the run's when no evaluation is open (the verdict).
      def judge(action = "score", &)
        trace(@judge_name, action, judge: true, &)
      end

      # The correlation metadata in scope, or nil outside a run. A result's
      # values win over the run's.
      def current
        context = ActiveSupport::IsolatedExecutionState[STATE_KEY]
        return nil unless context

        context.fetch(:run, {}).merge(context[:result] || {})
      end

      private

      def run_metadata
        context = ActiveSupport::IsolatedExecutionState[STATE_KEY]
        context&.fetch(:run, nil) || {}
      end

      def with_context(context)
        previous = ActiveSupport::IsolatedExecutionState[STATE_KEY]
        ActiveSupport::IsolatedExecutionState[STATE_KEY] = context
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[STATE_KEY] = previous
      end

      def trace(name, action, judge:, &block)
        return block.call unless @tracer

        context = ActiveSupport::IsolatedExecutionState[STATE_KEY] || {}
        correlation = context.fetch(:run, {}).merge(context[:result] || {})
        attributes = correlation.slice(*@trace_keys).transform_keys { |key| "eval.#{key}" }
        # A replay belongs to the evaluation that opened it and nowhere else, so
        # it records no trace id when called outside one. A judge call outside an
        # evaluation is the verdict, which belongs to the run.
        target = judge ? (context[:result] || context[:run]) : context[:result]

        @tracer.call(name, action: action, attributes: attributes, on_trace: recorder(target, judge: judge), &block)
      end

      def recorder(target, judge:)
        lambda do |trace|
          next unless target

          if judge
            (target["judge_trace_ids"] ||= []) << trace.trace_id
          else
            target["trace_id"] = trace.trace_id
          end
        end
      end
    end
  end
end
