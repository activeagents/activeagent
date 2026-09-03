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
    # least. FaultDiagnosis assigns exactly one per failing result.
    FAULTS = %w[
      run_error
      tool_error
      missing_capability
      expected_tool_not_called
      forbidden_content
      missing_content
      low_quality
    ].freeze

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

    def as_json_summary
      {
        id: id,
        scenario_id: evaluation_scenario_id,
        scenario_key: scenario.key,
        group: scenario.group,
        prompt: scenario.prompt,
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
        diagnosis: diagnosis,
        error_message: error_message,
        agent_run_id: agent_run_id
      }
    end
  end
end
