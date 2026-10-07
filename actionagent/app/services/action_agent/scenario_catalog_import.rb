# frozen_string_literal: true

module ActionAgent
  # Imports a scenario catalog document into the owner's records: products,
  # sets and scenarios are matched by key and replaced, so the document is
  # the truth and importing it twice changes nothing. The catalog keeps the
  # canonical document and its digest, and is written to Active Storage when
  # the host has it.
  #
  #   ScenarioCatalogImport.new(owner: account, document: yaml, agents: ActionAgent.agents_for(account)).call
  #
  # A product's `agent:` is resolved among +agents+ by name, and a project
  # among +projects+ by the product's `repository` or `project` entry, so a
  # catalog written for a repository finds the project that boots it.
  class ScenarioCatalogImport
    # Raised for a document that cannot be imported, with the reason a
    # person can act on.
    class Invalid < StandardError; end

    attr_reader :catalog

    def initialize(owner:, document:, catalog: nil, name: nil, source_kind: "upload", source_path: nil, agents: nil, projects: nil)
      @owner = owner
      @document = document.to_s
      @catalog = catalog
      @name = name
      @source_kind = source_kind
      @source_path = source_path
      @agents = agents
      @projects = projects
    end

    # @return [ScenarioCatalog] the imported catalog
    def call
      if @document.bytesize > ScenarioCatalog::MAX_BYTES
        raise Invalid, "The catalog is larger than #{ScenarioCatalog::MAX_BYTES / 1.megabyte} MB"
      end

      parsed = ActiveAgent::Evals::Catalog.parse(@document, name: @name)
      if parsed.scenario_count > ScenarioCatalog::MAX_SCENARIOS
        raise Invalid, "The catalog holds #{parsed.scenario_count} scenarios; the limit is #{ScenarioCatalog::MAX_SCENARIOS}"
      end

      ScenarioCatalog.transaction do
        @catalog ||= find_or_initialize(parsed.key)
        @catalog.assign_attributes(
          key: parsed.key, name: parsed.name, description: parsed.description,
          source_kind: @source_kind, source_path: @source_path,
          metadata: parsed.metadata, document: parsed.to_yaml, digest: parsed.digest
        )
        @catalog.save!
        replace_products(parsed)
      end
      @catalog.sync_to_storage!
      @catalog
    rescue ActiveAgent::Evals::Catalog::InvalidDocument => e
      raise Invalid, e.message
    rescue ActiveRecord::RecordInvalid => e
      raise Invalid, e.record.errors.full_messages.to_sentence
    end

    private

    def find_or_initialize(key)
      catalog = ScenarioCatalog.for_owner(@owner).find_or_initialize_by(key: key)
      catalog.owner = @owner if catalog.new_record? && @owner
      catalog
    end

    def replace_products(parsed)
      keep = parsed.products.map(&:key)
      @catalog.products.where.not(key: keep).destroy_all

      parsed.products.each do |entry|
        product = @catalog.products.find_or_initialize_by(key: entry.key)
        product.assign_attributes(
          name: entry.name, description: entry.description, agent_name: entry.agent,
          position: entry.position, metadata: entry.metadata,
          agent: resolve_agent(entry), project: resolve_project(entry)
        )
        product.save!
        replace_sets(product, entry)
      end
    end

    def replace_sets(product, entry)
      product.sets.where.not(key: entry.sets.map(&:key)).destroy_all

      entry.sets.each do |set_entry|
        set = product.sets.find_or_initialize_by(key: set_entry.key)
        set.assign_attributes(
          name: set_entry.name, description: set_entry.description, judge: set_entry.judge,
          criteria: set_entry.criteria, metadata: set_entry.metadata, position: set_entry.position
        )
        set.save!
        replace_scenarios(set, set_entry)
      end
    end

    def replace_scenarios(set, set_entry)
      set.scenarios.where.not(key: set_entry.scenarios.map(&:key)).destroy_all

      set_entry.scenarios.each do |scenario|
        record = set.scenarios.find_or_initialize_by(key: scenario.key)
        record.assign_attributes(
          prompt: scenario.prompt, notes: scenario.notes, expectations: scenario.expectations,
          tags: scenario.tags, params: scenario.params, production_only: scenario.production_only?,
          position: scenario.position
        )
        record.save!
      end
    end

    # The owner's agent the product's `agent:` names, kept as the product's
    # agent; a name that matches nothing stays as agent_name alone.
    def resolve_agent(entry)
      return nil if entry.agent.blank? || @agents.nil?

      @agents.find_by(name: entry.agent)
    end

    # The project the product's `project:` (a project id or name) or
    # `repository:` (owner/name) names among +projects+.
    def resolve_project(entry)
      return nil if @projects.nil?

      reference = entry.metadata["project"]
      repository = entry.metadata["repository"]
      if reference.present?
        reference.to_s.match?(/\A\d+\z/) ? @projects.find_by(id: reference) : @projects.find_by(name: reference.to_s)
      elsif repository.present?
        @projects.find_by(repository: repository.to_s)
      end
    end
  end
end
