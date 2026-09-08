# frozen_string_literal: true

module ActionAgent
  # One user-authored task an evaluation replays through its agent: the
  # message a user would send, the group of related tasks it belongs to, and
  # what a passing answer is expected to do.
  #
  # `expectations` holds the scenario-level checks ScenarioEvaluationRunner
  # scores in addition to the evaluation's criteria:
  #
  #   "tools"        — tool names the agent is expected to call (any one of them)
  #   "contains"     — substrings or patterns the answer must include
  #   "not_contains" — substrings or patterns the answer must avoid
  #
  # `key` is stable within the suite ("blame_3"), so results of successive
  # runs line up by scenario even after the suite is re-imported.
  class EvaluationScenario < ApplicationRecord
    belongs_to :evaluation
    has_many :results, class_name: "EvaluationScenarioResult", foreign_key: :evaluation_scenario_id,
      dependent: :destroy, inverse_of: :scenario

    validates :key, presence: true, uniqueness: { scope: :evaluation_id }
    validates :prompt, presence: true

    scope :enabled, -> { where(enabled: true) }
    scope :ordered, -> { order(:position, :id) }
    scope :in_group, ->(group) { where(group: group) }

    def expectations
      value = super
      value.is_a?(Hash) ? value : {}
    end

    def expected_tools
      Array(expectations["tools"]).map(&:to_s).reject(&:blank?)
    end

    def expected_patterns
      Array(expectations["contains"]).map(&:to_s).reject(&:blank?)
    end

    def forbidden_patterns
      Array(expectations["not_contains"]).map(&:to_s).reject(&:blank?)
    end

    def as_json_summary
      {
        id: id,
        key: key,
        group: group,
        prompt: prompt,
        notes: notes,
        expectations: expectations,
        position: position,
        enabled: enabled
      }
    end
  end
end
