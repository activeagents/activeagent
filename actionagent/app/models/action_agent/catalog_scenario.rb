# frozen_string_literal: true

module ActionAgent
  # One scenario of a catalog set, as the document gave it. It becomes an
  # EvaluationScenario of the set's evaluation when the set is materialized;
  # tags and params stay here, for the catalog's readers, since the
  # evaluation's scenarios do not carry them.
  class CatalogScenario < ApplicationRecord
    belongs_to :set, class_name: "ActionAgent::ScenarioSet", foreign_key: :scenario_set_id, inverse_of: :scenarios

    validates :key, presence: true, length: { maximum: 200 }, uniqueness: { scope: :scenario_set_id }
    validates :prompt, presence: true

    scope :enabled, -> { where(enabled: true) }

    def expectations
      value = self[:expectations]
      value.is_a?(Hash) ? value : {}
    end

    def tags
      Array(self[:tags]).map(&:to_s)
    end

    def params
      value = self[:params]
      value.is_a?(Hash) ? value : {}
    end

    # @return [ActiveAgent::Evals::Scenario]
    def to_scenario
      ActiveAgent::Evals::Scenario.from_hash(to_document.merge("position" => position), group: set.key, group_name: set.name)
    end

    def to_document
      {
        "key" => key,
        "prompt" => prompt,
        "expect" => expectations.presence,
        "notes" => notes,
        "tags" => tags.presence,
        "params" => params.presence,
        "production_only" => (true if production_only?)
      }.compact
    end

    # The attributes Evaluation#replace_scenarios! takes.
    def evaluation_attributes(index)
      {
        "key" => key,
        "prompt" => prompt,
        "group" => set.key,
        "notes" => notes,
        "expectations" => expectations,
        "position" => position || index,
        "enabled" => enabled
      }
    end

    def summary
      {
        id: id,
        key: key,
        prompt: prompt,
        notes: notes,
        expectations: expectations,
        tags: tags,
        params: params,
        production_only: production_only?,
        enabled: enabled?,
        position: position
      }
    end
  end
end
