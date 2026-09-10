# frozen_string_literal: true

module ActionAgent
  # What one scenario produced under one model in one evaluation run: the
  # AgentRun that replayed it, the answer, the tools it called, its score per
  # criterion, and — when it fell short — the fault and the recommended fix.
  #
  # `fault` is one of FAULTS; `diagnosis` carries the evidence behind it and,
  # when a judge was available, its suggested tool or instruction change.
  class EvaluationScenarioResult < ApplicationRecord
    belongs_to :evaluation_run
    belongs_to :scenario, class_name: "EvaluationScenario", foreign_key: :evaluation_scenario_id, inverse_of: :results
    belongs_to :agent_run, optional: true

    enum :status, { pending: 0, passed: 1, failed: 2, errored: 3 }

    # Why a scenario did not pass, from the most mechanical cause to the
    # least; ActiveAgent::Evals::Diagnosis assigns exactly one per failing result.
    FAULTS = ActiveAgent::Evals::Diagnosis::FAULTS

    validates :model, presence: true
    validates :fault, inclusion: { in: FAULTS }, allow_nil: true

    scope :for_model, ->(model) { where(model: model) }
    scope :faulted, -> { where.not(fault: nil) }

    def tool_calls
      value = super
      value.is_a?(Array) ? value : []
    end

    def tool_names
      tool_calls.filter_map { |call| call.is_a?(Hash) ? (call["name"] || call[:name]) : call }.map(&:to_s)
    end

    def tool_errors
      tool_calls.select { |call| call.is_a?(Hash) && (call["error"] || call[:error]) }
    end

    # Adapter-provided correlation and context are stored alongside diagnosis
    # in a reserved JSON key, leaving the public diagnosis contract unchanged.
    def replay_metadata
      value = diagnosis&.dig("_replay_metadata")
      value.is_a?(Hash) ? value : {}
    end

    def evaluation_diagnosis
      (diagnosis || {}).except("_replay_metadata", "_scenario_snapshot")
    end

    # A catalog can be refreshed without changing what an earlier run asked
    # or expected. Older results did not record this snapshot.
    def evaluated_scenario
      snapshot = diagnosis&.dig("_scenario_snapshot")
      snapshot.is_a?(Hash) ? snapshot : scenario.as_json_summary.stringify_keys
    end

    def as_json_summary
      {
        id: id,
        scenario_id: evaluation_scenario_id,
        scenario_key: evaluated_scenario["key"],
        group: evaluated_scenario["group"],
        prompt: evaluated_scenario["prompt"],
        scenario: evaluated_scenario,
        model: model,
        provider: provider,
        status: status,
        score: score,
        scores: scores,
        output: output,
        tool_calls: tool_calls,
        duration_ms: duration_ms,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cost: cost&.to_f,
        fault: fault,
        recommendation: recommendation,
        diagnosis: evaluation_diagnosis,
        metadata: replay_metadata,
        error_message: error_message,
        agent_run_id: agent_run_id
      }
    end
  end
end
