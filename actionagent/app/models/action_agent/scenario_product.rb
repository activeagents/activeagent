# frozen_string_literal: true

module ActionAgent
  # A product in a scenario catalog: what its sets of scenarios run against.
  # That is a dashboard agent, a project (whose booted app the replays reach,
  # with its sandbox's browser), or, until one is chosen, the `agent:` name
  # the document gave.
  class ScenarioProduct < ApplicationRecord
    belongs_to :catalog, class_name: "ActionAgent::ScenarioCatalog", foreign_key: :scenario_catalog_id, inverse_of: :products
    belongs_to :agent, class_name: "ActionAgent::Agent", optional: true
    belongs_to :project, class_name: "ActionAgent::Project", optional: true
    has_many :sets, -> { order(:position, :id) }, class_name: "ActionAgent::ScenarioSet",
      foreign_key: :scenario_product_id, inverse_of: :product, dependent: :destroy

    validates :key, presence: true, format: { with: ScenarioCatalog::KEY_FORMAT }, length: { maximum: 120 },
      uniqueness: { scope: :scenario_catalog_id }
    validates :name, presence: true, length: { maximum: 200 }

    def metadata
      value = self[:metadata]
      value.is_a?(Hash) ? value : {}
    end

    # The product's named criteria lists, as the catalog's `criteria:` gives
    # them: list name => criterion hashes. A stored value that is not such a
    # mapping, and a list left with no criterion, read as no list.
    # @return [Hash{String => Array<Hash>}]
    def criteria
      value = self[:criteria]
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(name, list), lists|
        entries = Array(list).select { |criterion| criterion.is_a?(Hash) } if list.is_a?(Array)
        lists[name.to_s] = entries if entries.present?
      end
    end

    # The agent a set of this product runs against when the caller names
    # none: the product's agent, else the project's agent under test, else
    # the owner's agent named by the document.
    # @param candidates [ActiveRecord::Relation, nil] the agents the caller may run
    # @return [Agent, nil]
    def target_agent(candidates = nil)
      agent || project&.target_agent || (agent_name.present? && candidates ? candidates.find_by(name: agent_name) : nil)
    end

    def to_document
      {
        "key" => key,
        "name" => name,
        "description" => description,
        "agent" => agent_name.presence || agent&.name,
        "criteria" => criteria.presence,
        "sets" => sets.map(&:to_document)
      }.merge(metadata).compact
    end

    def summary
      {
        id: id,
        key: key,
        name: name,
        description: description,
        agent_name: agent_name,
        agent: agent && { id: agent.id, name: agent.name },
        project: project && { id: project.id, name: project.name, repository: project.repository, ref: project.checkout_ref },
        set_count: sets.size,
        scenario_count: sets.sum { |set| set.scenarios.size }
      }
    end
  end
end
