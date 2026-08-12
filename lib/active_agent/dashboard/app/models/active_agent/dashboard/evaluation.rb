# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # An evaluation definition for an agent: a named set of criteria scored
    # against the agent's recorded behavior — its recent generations
    # (solid_agent's agent_generations dataset) and its telemetry traces.
    #
    # Criteria are stored as an array of { "key", "type", "config" } hashes.
    # Rule-based criterion types score each sampled generation
    # deterministically; telemetry criterion types score aggregates over the
    # agent's traces (error rate, latency); the llm_judge type asks a judge
    # model to score each sample and requires a configured provider.
    class Evaluation < ApplicationRecord
      belongs_to :agent
      has_many :evaluation_runs, dependent: :destroy

      # judge_defined: the judge model authors the KPI criteria itself from the
      # agent's instructions + sample interactions on the first run, then scores
      # against them (criteria stay persisted/editable so scores are comparable
      # across runs and models).
      JUDGE_KINDS = %w[rules llm judge_defined].freeze

      RULE_CRITERION_TYPES = %w[
        response_present min_length max_latency_ms token_budget contains not_contains
      ].freeze
      # Scored from the agent's telemetry traces (aggregate, not per-sample).
      TELEMETRY_CRITERION_TYPES = %w[trace_error_rate trace_latency].freeze
      CRITERION_TYPES = (RULE_CRITERION_TYPES + TELEMETRY_CRITERION_TYPES + %w[llm_judge]).freeze

      validates :name, presence: true, uniqueness: { scope: :agent_id }
      validates :judge_kind, inclusion: { in: JUDGE_KINDS }
      validates :sample_size, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
      validate :validate_criteria

      scope :recent, -> { order(updated_at: :desc) }

      def latest_run
        evaluation_runs.order(created_at: :desc).first
      end

      def judge_defined?
        judge_kind == "judge_defined"
      end

      # Candidate models for per-cohort comparison scoring (config, optional).
      def compare_models
        Array(config["compare_models"]).map(&:to_s).reject(&:blank?)
      end

      def run!
        EvaluationRunnerService.call(self)
      end

      def llm_criteria
        criteria.select { |c| c["type"] == "llm_judge" }
      end

      private

      def validate_criteria
        if criteria.blank?
          # judge_defined evaluations start empty — the judge authors the KPIs
          # on the first run.
          errors.add(:criteria, "must include at least one criterion") unless judge_defined?
          return
        end

        criteria.each do |criterion|
          unless criterion.is_a?(Hash) && criterion["key"].present?
            errors.add(:criteria, "entries must have a key")
            next
          end

          unless CRITERION_TYPES.include?(criterion["type"])
            errors.add(:criteria, "unknown criterion type #{criterion['type']}")
          end
        end
      end
    end
  end
end
