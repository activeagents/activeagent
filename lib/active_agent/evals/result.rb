# frozen_string_literal: true

module ActiveAgent
  module Evals
    # One scenario replayed under one model: the Replay, its scores, and the
    # diagnosis when it fell short.
    #
    # `status` is "errored" when the run raised, "failed" when a fault was
    # assigned, and "passed" otherwise. `diagnosis` is the Diagnosis::Result
    # hash, with a `"judge"` sub-hash when a Judge refined it.
    Result = Struct.new(:scenario, :spec, :replay, :scores, :score, :status, :diagnosis, keyword_init: true) do
      def passed?
        status == "passed"
      end

      def failed?
        status == "failed"
      end

      def errored?
        status == "errored"
      end

      def label
        spec.label
      end

      def model
        spec.model
      end

      def provider
        spec.provider
      end

      def fault
        diagnosis && diagnosis["fault"]
      end

      def summary
        diagnosis && diagnosis["summary"]
      end

      def recommendation
        diagnosis && diagnosis["recommendation"]
      end

      def suggested_tool
        diagnosis&.dig("judge", "suggested_tool")
      end

      # Where the replay's cost came from, as the caller recorded it in the
      # replay metadata: "reported" (the caller priced it), "estimated"
      # (tokens × a model rate), "no_usage" (nothing was generated, so $0.00)
      # or "unpriced" (nothing to price it from). A cost with no record is
      # the caller's own figure; no cost at all is unpriced.
      def cost_source
        recorded = replay_meta("cost_source").to_s
        return recorded if recorded.present?

        replay.cost.nil? ? "unpriced" : "reported"
      end

      def estimated_cost?
        cost_source == "estimated"
      end

      # The rate an estimated cost was worked out at, `{ "input", "output",
      # "source" }` in $ per million tokens, or nil.
      def cost_rate
        rate = replay_meta("cost_rate")
        rate.is_a?(Hash) ? rate.transform_keys(&:to_s) : nil
      end

      # What the judge spent on this result — `{ "calls", "input_tokens",
      # "output_tokens", "cost", "model", "by_kind", "source" }` — or nil
      # when no judge was asked about it.
      def judge_usage
        usage = replay_meta("judge_usage")
        usage.is_a?(Hash) ? usage.transform_keys(&:to_s) : nil
      end

      def to_h
        {
          "scenario_key" => scenario.key,
          "group" => scenario.group,
          "prompt" => scenario.prompt,
          "label" => label,
          "provider" => provider,
          "model" => model,
          "status" => status,
          "score" => score,
          "scores" => scores,
          "answer" => replay.answer,
          "tool_calls" => replay.tool_calls,
          "duration_ms" => replay.duration_ms,
          "input_tokens" => replay.input_tokens,
          "output_tokens" => replay.output_tokens,
          "cost" => replay.cost,
          "error" => replay.error,
          "fault" => fault,
          "recommendation" => recommendation,
          "diagnosis" => diagnosis,
          "judge_usage" => judge_usage,
          "metadata" => replay.metadata
        }.compact
      end

      private

      # A caller may key the replay metadata with symbols.
      def replay_meta(key)
        metadata = replay.metadata
        metadata[key] || metadata[key.to_sym]
      end
    end
  end
end
