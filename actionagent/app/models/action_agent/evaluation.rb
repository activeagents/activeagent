# frozen_string_literal: true

module ActionAgent
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
    has_many :scenarios, class_name: "EvaluationScenario", dependent: :destroy

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

    # A scenario evaluation replays its own prompts rather than sampling the
    # agent's recorded generations.
    def scenario_suite?
      scenarios.any?
    end

    def scenario_groups
      # The index preloads scenarios for a page of evaluations; read the
      # loaded association there rather than querying once per suite.
      return scenarios.filter_map { |scenario| scenario.group.presence }.uniq.sort if scenarios.loaded?

      scenarios.where.not(group: [ nil, "" ]).distinct.order(:group).pluck(:group)
    end

    # Runs the evaluation. `selection` narrows a scenario evaluation to some of
    # its scenarios (`scenario_ids`, `keys`, `group`) and/or to specific
    # `models`; it is ignored by a generation-sampling evaluation.
    def run!(run: nil, **selection)
      # A run created ahead of time (run_later!) is the scenario runner's even
      # if the suite has since lost its scenarios: it fails that run with
      # "No scenarios selected" rather than leaving it pending forever.
      if run || scenario_suite?
        ScenarioEvaluationRunner.call(self, selection: selection, run: run)
      else
        EvaluationRunnerService.call(self)
      end
    end

    # Creates the run now and executes it in the background, so a suite of
    # many scenarios under several models does not have to finish inside one
    # request. Returns the pending EvaluationRun.
    def run_later!(**selection)
      run = evaluation_runs.create!(status: :pending, selection: selection.deep_stringify_keys)
      EvaluationRunJob.perform_later(id, run.id, selection.deep_stringify_keys)
      run
    end

    # Replaces the suite with the scenarios described by +attributes+ (the
    # ActiveAgent::Evals::ScenarioParser output). Keys already in the suite keep their records, so
    # earlier runs' results still resolve to their scenario, and keep their
    # enabled flag unless the attributes set it (a paste cannot).
    def replace_scenarios!(attributes)
      transaction do
        keep = attributes.map { |attrs| attrs["key"] }
        scenarios.where.not(key: keep).destroy_all

        attributes.each_with_index do |attrs, index|
          scenario = scenarios.find_or_initialize_by(key: attrs["key"])
          scenario.assign_attributes(
            prompt: attrs["prompt"],
            group: attrs["group"],
            notes: attrs["notes"],
            expectations: attrs["expectations"] || {},
            position: attrs.fetch("position", index),
            enabled: attrs.fetch("enabled") { scenario.new_record? || scenario.enabled }
          )
          scenario.save!
        end
      end
      scenarios.reload
    end

    def llm_criteria
      criteria.select { |c| c["type"] == "llm_judge" }
    end

    private

    def validate_criteria
      if criteria.blank?
        # judge_defined evaluations start empty — the judge authors the KPIs
        # on the first run — and a scenario suite is scored by its scenarios'
        # own expectations even with no criteria.
        errors.add(:criteria, "must include at least one criterion") unless judge_defined? || scenarios.any?
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
