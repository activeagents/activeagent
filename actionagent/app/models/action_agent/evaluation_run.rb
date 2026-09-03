# frozen_string_literal: true

module ActionAgent
  # One execution of an Evaluation over a sample of the agent's generations.
  # scores: { criterion_key => { "score", "min", "max", "passed", "total" } }
  class EvaluationRun < ApplicationRecord
    belongs_to :evaluation

    enum :status, { pending: 0, running: 1, complete: 2, failed: 3 }

    scope :recent, -> { order(created_at: :desc) }

    # scores is not uniformly { criterion => stats }: a comparison run also
    # records "_"-prefixed metadata (EvaluationRunnerService writes
    # "_missing_models" as an Array and "_verdict"), and each of its criteria
    # is a cohort map of model => stats rather than a single stats hash.
    # Only real criterion scores are averaged; anything else is ignored
    # rather than raising and taking the whole Evaluations page down.
    def average_score
      values = (scores || {}).reject { |key, _| key.to_s.start_with?("_") }.filter_map do |_key, value|
        criterion_score(value) if value.is_a?(Hash)
      end
      return nil if values.empty?

      (values.sum.to_f / values.size).round(3)
    end

    private

    # A criterion is either scored directly ({ "score" => 0.8, ... }) or, on a
    # comparison run, a map of model => stats; that cohort's mean is the
    # criterion's headline score. Skipped criteria carry no score at all.
    def criterion_score(value)
      return value["score"] if value["score"].is_a?(Numeric)

      cohort = value.each_value.filter_map do |stats|
        stats["score"] if stats.is_a?(Hash) && stats["score"].is_a?(Numeric)
      end
      return nil if cohort.empty?

      cohort.sum.to_f / cohort.size
    end
  end
end
