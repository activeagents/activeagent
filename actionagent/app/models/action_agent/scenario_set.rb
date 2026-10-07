# frozen_string_literal: true

module ActionAgent
  # A named set of scenarios in a catalog product: a smoke set, the UAT of
  # one pull request, a regression list. A set runs by becoming an
  # evaluation of the agent under test (#materialize!), named
  # "<catalog>/<product>/<set>", whose scenarios are replaced from the set
  # each time, so the evaluation's runs, results, traces and recordings are
  # the set's history, and the catalog document can change without changing
  # what an earlier run asked (EvaluationScenarioResult keeps a snapshot).
  class ScenarioSet < ApplicationRecord
    # Raised by #materialize! and #run! when no agent is known to run against.
    class NoAgent < StandardError; end

    belongs_to :product, class_name: "ActionAgent::ScenarioProduct", foreign_key: :scenario_product_id, inverse_of: :sets
    belongs_to :evaluation, class_name: "ActionAgent::Evaluation", optional: true
    has_many :scenarios, -> { order(:position, :id) }, class_name: "ActionAgent::CatalogScenario",
      foreign_key: :scenario_set_id, inverse_of: :set, dependent: :destroy

    validates :key, presence: true, format: { with: ScenarioCatalog::KEY_FORMAT }, length: { maximum: 120 },
      uniqueness: { scope: :scenario_product_id }
    validates :name, presence: true, length: { maximum: 200 }

    delegate :catalog, to: :product

    def judge
      value = self[:judge]
      value.is_a?(Hash) ? value : {}
    end

    def criteria
      Array(self[:criteria]).select { |criterion| criterion.is_a?(Hash) }
    end

    def metadata
      value = self[:metadata]
      value.is_a?(Hash) ? value : {}
    end

    # The evaluation's name: the catalog, product and set keys.
    def evaluation_name
      "#{catalog.key}/#{product.key}/#{key}".first(EvaluationReportImport::MAX_EVALUATION_NAME)
    end

    # The reference an evaluation and its runs keep to this set.
    def catalog_reference
      {
        "catalog_id" => catalog.id,
        "catalog_key" => catalog.key,
        "product_key" => product.key,
        "set_key" => key,
        "set_id" => id,
        "digest" => catalog.digest
      }
    end

    # Creates or refreshes the evaluation of +agent+ this set runs as, with
    # the set's judge and criteria, and its scenarios replaced from the
    # set's (a scenario the set dropped is disabled, not destroyed, so runs
    # that scored it still resolve their results). Remembers the evaluation.
    #
    # @param agent [Agent] the agent under test; the product's by default
    # @return [Evaluation]
    def materialize!(agent: nil)
      agent ||= product.target_agent
      raise NoAgent, "Choose the agent to run #{evaluation_name} against: the product names none" if agent.nil?

      attributes = scenarios.each_with_index.map { |scenario, index| scenario.evaluation_attributes(index) }
      transaction do
        target = evaluation if evaluation&.agent_id == agent.id
        target ||= agent.evaluations.find_or_initialize_by(name: evaluation_name)
        target.judge_kind = judge["kind"].to_s.presence || target.judge_kind.presence || "rules"
        target.judge_model = judge["model"].to_s.presence if judge["model"].present?
        target.criteria = criteria if criteria.present?
        target.config = target.config.merge("catalog" => catalog_reference)
        # An evaluation with neither criteria nor scenarios is invalid, so a
        # new one gets its scenarios before the save.
        attributes.each { |attrs| target.scenarios.build(attrs.except("enabled")) } if target.new_record?
        target.save!
        target.replace_scenarios!(attributes, on_removed: :disable) unless target.previously_new_record?
        update!(evaluation: target) if evaluation_id != target.id
        target
      end
    end

    # Materializes and runs the set. Against a project, the run waits for the
    # project's sandbox and reaches it with its browser, as the project's own
    # evaluation does (ProjectEvaluationJob); otherwise the evaluation runs
    # in the background with the given selection (models, keys).
    #
    # @return [EvaluationRun]
    def run!(agent: nil, project: nil, mount_url: nil, **selection)
      agent ||= project&.target_agent || product.target_agent
      if project && agent.nil?
        raise NoAgent, "Choose the agent to evaluate in project #{project.name} first"
      end

      target = materialize!(agent: agent)
      reference = { "catalog" => catalog_reference }
      if project
        sandbox = project.current_sandbox_session
        raise NoAgent, "Boot project #{project.name} before running #{evaluation_name} against it" if sandbox.nil?

        run = target.evaluation_runs.create!(status: :pending,
          selection: reference.merge("project_id" => project.id, "sandbox_id" => sandbox.session_id).merge(selection.deep_stringify_keys))
        ProjectEvaluationJob.perform_later(project.id, run.id, mount_url)
        run
      else
        target.run_later!(**selection.deep_stringify_keys.merge(reference).deep_symbolize_keys)
      end
    end

    def to_document
      {
        "key" => key,
        "name" => name,
        "description" => description,
        "judge" => judge.presence,
        "criteria" => criteria.presence,
        "scenarios" => scenarios.map(&:to_document)
      }.merge(metadata).compact
    end

    def summary
      {
        id: id,
        key: key,
        name: name,
        description: description,
        judge: judge,
        criteria_count: criteria.size,
        scenario_count: scenarios.size,
        evaluation: evaluation && { id: evaluation.id, name: evaluation.name, agent_id: evaluation.agent_id },
        latest_run: evaluation&.latest_run&.then { |run| { id: run.id, status: run.status, created_at: run.created_at } }
      }
    end
  end
end
