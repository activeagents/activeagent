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
    # Raised by #merge_scenarios! for a merge that would leave the suite
    # holding more scenarios than its limit.
    class ScenarioLimitExceeded < StandardError; end

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
    # Archived evaluations keep their runs but leave the index and its
    # tiles unless asked for (see #archive!). The mark lives in the config
    # JSON, so the filter reads it with each database's own JSON path.
    scope :archived, -> { where("#{archived_at_sql} IS NOT NULL") }
    scope :unarchived, -> { where("#{archived_at_sql} IS NULL") }

    # SQL reading config["archived_at"] on the connected database.
    def self.archived_at_sql
      case connection.adapter_name.to_s.downcase
      when /postgres/ then "#{quoted_table_name}.config ->> 'archived_at'"
      when /mysql|trilogy/ then "JSON_UNQUOTE(JSON_EXTRACT(#{quoted_table_name}.config, '$.archived_at'))"
      else "json_extract(#{quoted_table_name}.config, '$.archived_at')"
      end
    end

    # MySQL cannot give a JSON column a default, so a row inserted there
    # without `criteria` or `config` reads back nil. Both readers answer with
    # the empty value the column default supplies on other databases.
    def criteria
      super || []
    end

    def config
      super || {}
    end

    def latest_run
      evaluation_runs.order(created_at: :desc).first
    end

    # The newest run that finished: the one the evaluation's pass rate
    # describes. A newer run still pending, or one that failed, shows
    # beside it and never in its place. Read from the loaded association
    # when the index preloaded it.
    def headline_run
      if evaluation_runs.loaded?
        evaluation_runs.select(&:complete?).max_by { |run| [ run.created_at, run.id ] }
      else
        evaluation_runs.complete.order(created_at: :desc, id: :desc).first
      end
    end

    # --- archiving ---------------------------------------------------------
    #
    # An evaluation nobody maintains — its suite superseded, its agent
    # retired — keeps its history but stops counting: the index leaves it
    # out, and so do the pooled pass rate and the agent's scorecard. The
    # mark is config["archived_at"]; a new run or a published report clears
    # it, since either says the evaluation is alive after all.

    def archived_at
      value = config["archived_at"]
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    def archived?
      config["archived_at"].present?
    end

    def archive!
      update!(config: config.merge("archived_at" => Time.current.iso8601))
    end

    def unarchive!
      return unless archived?

      update!(config: config.except("archived_at"))
    end

    # Where this evaluation stands against the agent as it is now: whether
    # its headline run scored the current version (EvaluationStanding).
    # Memoized per instance; the index preloads what it needs.
    def standing_info
      @standing_info ||= EvaluationStanding.new(self)
    end

    attr_writer :standing_info

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
    # `on_removed:` decides what happens to a scenario the new attributes no
    # longer name: `:destroy` drops it, `:disable` keeps the row with
    # `enabled: false` so runs that scored it still resolve their results.
    def replace_scenarios!(attributes, on_removed: :destroy)
      raise ArgumentError, "on_removed must be :destroy or :disable" unless %i[destroy disable].include?(on_removed)

      transaction do
        keep = attributes.map { |attrs| attrs["key"] }
        removed = scenarios.where.not(key: keep)
        on_removed == :disable ? removed.update_all(enabled: false) : removed.destroy_all

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

    # Adds the scenarios of +attributes+ (ActiveAgent::Evals::ScenarioParser
    # output) whose keys the suite lacks, and updates the ones whose keys it
    # holds. A scenario whose key +attributes+ do not name is never touched,
    # unlike #replace_scenarios!, which treats its input as the whole suite.
    #
    #   - An existing key gets the given prompt, group, notes and
    #     expectations, and a group, notes or expectations the attributes
    #     leave out clears the stored one. It keeps its record, results,
    #     position and enabled flag unless the attributes set "position" or
    #     "enabled".
    #   - A new key is appended after the suite's last position, in input
    #     order, enabled unless the attributes say otherwise.
    #
    # ScenarioParser output carries each scenario's position within its own
    # paste, which an existing key would take; remove "position" from parser
    # output to keep the suite's order.
    #
    # Nothing is written when the merge raises.
    #
    # @param limit [Integer, nil] the most scenarios the suite may hold
    #   afterwards
    # @raise [ArgumentError] when a scenario has no key or two share one
    # @raise [ScenarioLimitExceeded] when the suite would pass +limit+
    # @return [Hash{Symbol => Array<String>}] the keys under :added, :updated
    #   (an existing scenario that changed) and :unchanged
    def merge_scenarios!(attributes, limit: nil)
      keys = attributes.map { |attrs| attrs["key"].to_s }
      raise ArgumentError, "every merged scenario needs a key" if keys.any?(&:blank?)

      repeated = keys.tally.select { |_, count| count > 1 }.keys
      raise ArgumentError, "scenario keys repeat: #{repeated.join(', ')}" if repeated.any?

      merged = { added: [], updated: [], unchanged: [] }
      # Locked, so two merges into one suite cannot both pass the limit or
      # both add the same key.
      with_lock do
        existing = scenarios.where(key: keys).index_by(&:key)
        added = keys.count { |key| !existing.key?(key) }
        if limit && (held = scenarios.count) + added > limit
          raise ScenarioLimitExceeded, "Scenario limit reached (#{limit} per evaluation): the evaluation holds #{held} " \
                                       "and this merge adds #{added}"
        end

        next_position = (scenarios.maximum(:position) || -1) + 1
        attributes.each do |attrs|
          scenario = existing[attrs["key"].to_s]
          if scenario.nil?
            scenarios.create!(scenario_fields(attrs).merge(key: attrs["key"].to_s, position: next_position,
                                                          enabled: attrs.fetch("enabled", true)))
            next_position += 1
            merged[:added] << attrs["key"].to_s
            next
          end

          fields = scenario_fields(attrs)
          # A row stored without expectations reads them as {}, and is not
          # changed by being given {}.
          fields.delete(:expectations) if scenario.expectations == fields[:expectations]
          scenario.assign_attributes(fields)
          scenario.position = attrs["position"] if attrs.key?("position")
          scenario.enabled = attrs["enabled"] if attrs.key?("enabled")
          if scenario.changed?
            scenario.save!
            merged[:updated] << scenario.key
          else
            merged[:unchanged] << scenario.key
          end
        end
      end
      merged
    ensure
      # create! adds each record to the association, and a rolled-back one
      # stays there as a new record that the evaluation's next save writes.
      scenarios.reset
    end

    def llm_criteria
      criteria.select { |c| c["type"] == "llm_judge" }
    end

    private

    def scenario_fields(attrs)
      { prompt: attrs["prompt"], group: attrs["group"], notes: attrs["notes"], expectations: attrs["expectations"] || {} }
    end

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
