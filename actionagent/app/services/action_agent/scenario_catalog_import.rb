# frozen_string_literal: true

module ActionAgent
  # Imports a scenario catalog document into the owner's records: products,
  # sets and scenarios are matched by key. In "replace" mode (the default)
  # the document is the truth, so what it leaves out is removed and
  # importing it twice changes nothing; in "merge" mode what it leaves out
  # is kept, so an export of one set or a few scenarios can be imported back
  # into the whole catalog. The catalog keeps the canonical document and its
  # digest, and is written to Active Storage when the host has it.
  #
  #   ScenarioCatalogImport.new(owner: account, document: yaml, agents: ActionAgent.agents_for(account)).call
  #
  # #preview answers what #call would change, by key, without writing.
  #
  # A product's `agent:` is resolved among +agents+ by name, and a project
  # among +projects+ by the product's `repository` or `project` entry, so a
  # catalog written for a repository finds the project that boots it.
  class ScenarioCatalogImport
    # Raised for a document that cannot be imported, with the reason a
    # person can act on.
    class Invalid < StandardError; end

    MODES = %w[replace merge].freeze
    # The changes #preview lists; the counts cover all of them.
    PREVIEW_LIMIT = 500

    attr_reader :catalog, :source_path

    def initialize(owner:, document:, catalog: nil, name: nil, source_kind: "upload", source_path: nil, agents: nil, projects: nil, mode: "replace")
      @owner = owner
      @document = document.to_s
      @catalog = catalog
      @name = name
      @source_kind = source_kind
      @source_path = source_path
      @agents = agents
      @projects = projects
      @mode = mode.to_s.presence || "replace"
      raise Invalid, "The import mode is replace or merge" unless MODES.include?(@mode)
    end

    # @return [ScenarioCatalog] the imported catalog
    def call
      parsed = parse

      ScenarioCatalog.transaction do
        @catalog ||= find_or_initialize(parsed.key)
        merging = merge? && @catalog.persisted?
        @catalog.assign_attributes(
          key: parsed.key, source_kind: @source_kind, source_path: @source_path,
          name: merging ? (parsed_field(parsed, "name") || @catalog.name) : parsed.name,
          description: merging ? (parsed.description || @catalog.description) : parsed.description,
          metadata: merging ? @catalog.metadata.merge(parsed.metadata) : parsed.metadata,
          document: parsed.to_yaml, digest: parsed.digest
        )
        @catalog.save!
        replace_products(parsed)
        if merging
          @catalog.refresh_document!
          if @catalog.scenario_count > ScenarioCatalog::MAX_SCENARIOS
            raise Invalid, "The catalog would hold more than #{ScenarioCatalog::MAX_SCENARIOS} scenarios"
          end
        end
      end
      @catalog.sync_to_storage!
      @catalog
    rescue ActiveAgent::Evals::Catalog::InvalidDocument => e
      raise Invalid, e.message
    rescue ActiveRecord::RecordInvalid => e
      raise Invalid, e.record.errors.full_messages.to_sentence
    end

    # What #call would do, without writing: the catalog it imports into
    # (created or updated), counts by action, and the changes (up to
    # PREVIEW_LIMIT), each { level: product|set|scenario, path, action }
    # where action is create, update (the document changes a record by
    # that key), unchanged, remove (replace mode drops a record the document
    # leaves out) or keep (merge mode keeps it).
    #
    # @return [Hash]
    def preview
      parsed = parse
      existing = @catalog || ScenarioCatalog.for_owner(@owner).find_by(key: parsed.key)
      before = existing ? existing.to_catalog.to_h : {}
      after = parsed.to_h
      changes = []
      diff_level(changes, "product", "", list(before["products"]), list(after["products"]), "sets") do |path, old_product, new_product|
        diff_level(changes, "set", path, list(old_product["sets"]), list(new_product["sets"]), "scenarios") do |set_path, old_set, new_set|
          diff_level(changes, "scenario", set_path, list(old_set["scenarios"]), list(new_set["scenarios"]), nil)
        end
      end

      counts = Hash.new(0)
      changes.each { |change| counts[change[:action]] += 1 }
      {
        mode: @mode,
        catalog: {
          id: existing&.id, key: parsed.key, name: parsed.name,
          action: existing.nil? ? "create" : (catalog_fields(before) == catalog_fields(after) ? "unchanged" : "update")
        },
        scenario_count: parsed.scenario_count,
        counts: counts,
        changes: changes.reject { |change| change[:action] == "unchanged" }.first(PREVIEW_LIMIT)
      }
    rescue ActiveAgent::Evals::Catalog::InvalidDocument => e
      raise Invalid, e.message
    end

    private

    def merge?
      @mode == "merge"
    end

    def parse
      if @document.bytesize > ScenarioCatalog::MAX_BYTES
        raise Invalid, "The catalog is larger than #{ScenarioCatalog::MAX_BYTES / 1.megabyte} MB"
      end

      parsed = ActiveAgent::Evals::Catalog.parse(@document, name: @name)
      if parsed.scenario_count > ScenarioCatalog::MAX_SCENARIOS
        raise Invalid, "The catalog holds #{parsed.scenario_count} scenarios; the limit is #{ScenarioCatalog::MAX_SCENARIOS}"
      end

      parsed
    end

    # The document's own name, rather than the key the parser falls back to.
    def parsed_field(parsed, field)
      value = parsed.to_h[field]
      value unless field == "name" && value == parsed.key
    end

    def list(value)
      Array(value).select { |entry| entry.is_a?(Hash) }
    end

    def catalog_fields(document)
      document.except("products")
    end

    # Appends the changes between +old_entries+ and +new_entries+ (matched
    # by key) to +changes+, comparing each entry without its +children+, and
    # yields the pairs present in the document so their children are
    # compared too.
    def diff_level(changes, level, parent_path, old_entries, new_entries, children)
      old_by_key = old_entries.index_by { |entry| entry["key"].to_s }
      new_entries.each do |entry|
        key = entry["key"].to_s
        path = parent_path.empty? ? key : "#{parent_path}/#{key}"
        previous = old_by_key.delete(key)
        action =
          if previous.nil? then "create"
          elsif children ? previous.except(children) == entry.except(children) : previous == entry then "unchanged"
          else "update"
          end
        changes << { level: level, path: path, action: action }
        yield(path, previous || {}, entry) if children && block_given?
      end
      old_by_key.each_key do |key|
        path = parent_path.empty? ? key : "#{parent_path}/#{key}"
        changes << { level: level, path: path, action: merge? ? "keep" : "remove" }
      end
    end

    def find_or_initialize(key)
      catalog = ScenarioCatalog.for_owner(@owner).find_or_initialize_by(key: key)
      catalog.owner = @owner if catalog.new_record? && @owner
      catalog
    end

    def replace_products(parsed)
      @catalog.products.where.not(key: parsed.products.map(&:key)).destroy_all unless merge?
      offset = merge? ? next_position(@catalog.products) : 0

      parsed.products.each do |entry|
        product = @catalog.products.find_or_initialize_by(key: entry.key)
        product.assign_attributes(
          name: entry.name, description: entry.description, agent_name: entry.agent,
          metadata: entry.metadata, agent: resolve_agent(entry) || (merge? ? product.agent : nil),
          project: resolve_project(entry) || (merge? ? product.project : nil)
        )
        product.position = position_for(product, entry.position, offset)
        product.save!
        replace_sets(product, entry)
      end
    end

    def replace_sets(product, entry)
      product.sets.where.not(key: entry.sets.map(&:key)).destroy_all unless merge?
      offset = merge? ? next_position(product.sets) : 0

      entry.sets.each do |set_entry|
        set = product.sets.find_or_initialize_by(key: set_entry.key)
        set.assign_attributes(
          name: set_entry.name, description: set_entry.description, judge: set_entry.judge,
          criteria: set_entry.criteria, metadata: set_entry.metadata
        )
        set.position = position_for(set, set_entry.position, offset)
        set.save!
        replace_scenarios(set, set_entry)
      end
    end

    def replace_scenarios(set, set_entry)
      set.scenarios.where.not(key: set_entry.scenarios.map(&:key)).destroy_all unless merge?
      offset = merge? ? next_position(set.scenarios) : 0

      set_entry.scenarios.each do |scenario|
        record = set.scenarios.find_or_initialize_by(key: scenario.key)
        record.assign_attributes(
          prompt: scenario.prompt, notes: scenario.notes, expectations: scenario.expectations,
          tags: scenario.tags, params: scenario.params, production_only: scenario.production_only?, metadata: scenario.metadata
        )
        record.position = position_for(record, scenario.position, offset)
        record.save!
      end
    end

    # Replace mode takes the document's order. Merge mode keeps a record's
    # place and puts a new one after the records already there.
    def position_for(record, position, offset)
      return position unless merge?

      record.persisted? ? record.position : offset + position.to_i
    end

    def next_position(relation)
      (relation.maximum(:position) || -1) + 1
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
