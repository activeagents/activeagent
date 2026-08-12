# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # One execution of an Evaluation over a sample of the agent's generations.
    # scores: { criterion_key => { "score", "min", "max", "passed", "total" } }
    class EvaluationRun < ApplicationRecord
      belongs_to :evaluation

      enum :status, { pending: 0, running: 1, complete: 2, failed: 3 }

      scope :recent, -> { order(created_at: :desc) }

      def average_score
        values = scores.values.map { |s| s["score"] }.compact
        return nil if values.empty?

        (values.sum.to_f / values.size).round(3)
      end
    end
  end
end
