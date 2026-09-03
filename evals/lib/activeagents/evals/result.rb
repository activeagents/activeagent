# frozen_string_literal: true

module ActiveAgents
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
          "metadata" => replay.metadata
        }.compact
      end
    end
  end
end
