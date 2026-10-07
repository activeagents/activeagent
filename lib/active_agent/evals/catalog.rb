# frozen_string_literal: true

require "digest"

module ActiveAgent
  module Evals
    # A catalog of evaluation scenarios: the products an app evaluates, each
    # with the named sets of scenarios it is tested with. One YAML document,
    # or several layered like Suite's: a later document's product, set or
    # scenario with a key already present replaces it, a new key is appended.
    #
    #   catalog: support_desk
    #   name: Support Desk
    #   description: What the support agents are expected to handle
    #   products:
    #     - key: triage
    #       name: Triage agent
    #       agent: TriageAgent            # the agent class, or a dashboard agent's name
    #       sets:
    #         - key: smoke
    #           name: Smoke
    #           judge: { kind: rules }    # optional; an evaluation's judge_kind and judge_model
    #           criteria: []              # optional; an evaluation's criteria
    #           scenarios:
    #             - key: refund_request
    #               prompt: A customer asks for a refund on order 1042.
    #               expect:
    #                 tools: [lookup_order]
    #                 contains: [refund]
    #               notes: Looks the order up before answering.
    #               tags: [billing]
    #               params: { locale: en }
    #               production_only: false
    #
    # A suite document (`suite:`, `groups:`) loads as a catalog of one
    # product, named after the suite, whose sets are the suite's groups, so
    # every existing `config/evals/*.yml` is already a catalog.
    #
    # The catalog is the file format and nothing more: `scenarios` hands the
    # Runner its scenarios, `suite_for` gives one product's sets to code that
    # takes a Suite, and `to_yaml` writes the canonical document that
    # `digest` fingerprints, so two catalogs with the same content read the
    # same wherever they were written.
    class Catalog
      class NotFound < StandardError; end
      class InvalidDocument < StandardError; end

      # The keys a product, set or scenario may carry. Anything else is kept
      # under `metadata` so a document round-trips.
      PRODUCT_KEYS = %w[key name description agent sets].freeze
      SET_KEYS = %w[key name description judge criteria scenarios].freeze
      SCENARIO_KEYS = %w[key prompt expect expectations tools contains not_contains notes tags params production_only position].freeze
      CATALOG_KEYS = %w[catalog name description products suite groups].freeze

      Product = Struct.new(:key, :name, :description, :agent, :metadata, :sets, :position, keyword_init: true) do
        def set(key)
          sets.find { |set| set.key == key.to_s }
        end

        def scenarios
          sets.flat_map(&:scenarios)
        end
      end

      Set = Struct.new(:key, :name, :description, :judge, :criteria, :metadata, :scenarios, :position, keyword_init: true)

      attr_reader :key, :name, :description, :metadata, :products

      # Loads the documents at `paths` (missing files are skipped), base
      # first; raises NotFound when none exist.
      def self.load(*paths, name: nil)
        existing = paths.flatten.map(&:to_s).select { |path| File.exist?(path) }
        raise NotFound, "no scenario catalog at #{paths.flatten.join(', ')}" if existing.empty?

        documents = existing.map { |path| YAML.safe_load_file(path, aliases: true) || {} }
        new(documents, name: name || File.basename(existing.first, ".yml"))
      end

      # Parses YAML text. Raises InvalidDocument for YAML that is not a
      # document (a list, a scalar) or that YAML cannot read.
      def self.parse(text, name: nil)
        document = YAML.safe_load(text.to_s, aliases: true, permitted_classes: [ Symbol ])
        raise InvalidDocument, "a scenario catalog is a YAML mapping" unless document.is_a?(Hash)

        new([ document ], name: name)
      rescue Psych::SyntaxError => e
        raise InvalidDocument, "the catalog is not valid YAML: #{e.message}"
      end

      # @param documents [Hash, Array<Hash>] parsed YAML documents, base first
      def initialize(documents, name: nil)
        documents = Array.wrap(documents).map { |document| normalize(document.to_h.deep_stringify_keys, name) }
        @key = documents.filter_map { |doc| doc["catalog"].presence }.last.to_s.presence || name.to_s.presence
        raise InvalidDocument, "the catalog has no key: set `catalog:` in the document" if @key.blank?

        @name = documents.filter_map { |doc| doc["name"].presence }.last || @key
        @description = documents.filter_map { |doc| doc["description"].presence }.last
        @metadata = documents.map { |doc| doc.except(*CATALOG_KEYS) }.reduce({}, :merge)
        @products = build_products(merge_products(documents))
      end

      # The product with +key+, or NotFound.
      def product(key)
        products.find { |product| product.key == key.to_s } ||
          raise(NotFound, "no product #{key.inspect} in catalog #{self.key}")
      end

      # The set +set_key+ of product +product_key+, or NotFound.
      def set(product_key, set_key)
        product(product_key).set(set_key) ||
          raise(NotFound, "no set #{set_key.inspect} in product #{product_key.inspect} of catalog #{key}")
      end

      # Scenarios across the catalog, narrowed by product key, set key,
      # scenario keys, or any of them; `production_only` scenarios are
      # dropped unless `include_production_only` is true. Each scenario's
      # group is its set's key and its group_name the set's name.
      def scenarios(product: nil, set: nil, keys: nil, include_production_only: true)
        selected = products
        selected = selected.select { |entry| entry.key == product.to_s } if product.present?
        selected = selected.flat_map(&:sets)
        selected = selected.select { |entry| entry.key == set.to_s } if set.present?
        selected = selected.flat_map(&:scenarios)
        selected = selected.select { |scenario| Array(keys).map(&:to_s).include?(scenario.key) } if keys.present?
        selected = selected.reject(&:production_only?) unless include_production_only
        selected
      end

      def all_scenarios
        scenarios
      end

      def scenario_count
        products.sum { |product| product.sets.sum { |set| set.scenarios.size } }
      end

      # One product's sets as a Suite (every set a group), or one set alone,
      # for code that takes a suite: `Runner.new(scenarios: catalog.suite_for(:triage).scenarios, ...)`.
      def suite_for(product_key, set_key = nil)
        found = product(product_key)
        sets = set_key ? [ set(product_key, set_key) ] : found.sets
        Suite.new([ {
          "suite" => [ key, found.key, set_key ].compact.join("/"),
          "description" => found.description || description,
          "groups" => sets.map { |entry| set_document(entry) }
        } ])
      end

      # The canonical document: keys in a fixed order, nothing empty, so the
      # same content always reads the same.
      def to_h
        compact({
          "catalog" => key,
          "name" => name,
          "description" => description,
          "products" => products.map { |product| product_document(product) }
        }.merge(metadata))
      end

      def to_yaml
        YAML.dump(to_h)
      end

      # SHA-256 of the canonical document.
      def digest
        Digest::SHA256.hexdigest(to_yaml)
      end

      private

      # A suite document becomes a catalog document of one product.
      def normalize(document, name)
        return document if document.key?("products") || document.key?("catalog")
        return document unless document.key?("suite") || document.key?("groups")

        product_key = document["suite"].presence || name.to_s.presence || "default"
        {
          "catalog" => document["catalog"].presence || product_key,
          "name" => document["name"],
          "description" => document["description"],
          "products" => [ {
            "key" => product_key,
            "name" => document["name"].presence || product_key,
            "description" => document["description"],
            "sets" => Array(document["groups"])
          } ]
        }.compact
      end

      def merge_products(documents)
        documents.each_with_object([]) do |document, products|
          Array(document["products"]).each do |incoming|
            incoming = incoming.to_h.deep_stringify_keys
            raise InvalidDocument, "a product has no key" if incoming["key"].blank?

            existing = products.find { |product| product["key"] == incoming["key"].to_s }
            if existing
              %w[name description agent].each { |field| existing[field] = incoming[field] if incoming[field].present? }
              existing.merge!(incoming.except(*PRODUCT_KEYS))
              merge_sets(existing, Array(incoming["sets"]))
            else
              products << incoming.merge("key" => incoming["key"].to_s, "sets" => [])
                .tap { |product| merge_sets(product, Array(incoming["sets"])) }
            end
          end
        end
      end

      def merge_sets(product, incoming_sets)
        incoming_sets.each do |incoming|
          incoming = incoming.to_h.deep_stringify_keys
          raise InvalidDocument, "a set of product #{product['key'].inspect} has no key" if incoming["key"].blank?

          existing = product["sets"].find { |set| set["key"] == incoming["key"].to_s }
          if existing
            %w[name description judge criteria].each { |field| existing[field] = incoming[field] if incoming[field].present? }
            existing.merge!(incoming.except(*SET_KEYS))
            merge_scenarios(existing, Array(incoming["scenarios"]))
          else
            product["sets"] << incoming.merge("key" => incoming["key"].to_s, "scenarios" => [])
              .tap { |set| merge_scenarios(set, Array(incoming["scenarios"])) }
          end
        end
      end

      def merge_scenarios(set, incoming_scenarios)
        incoming_scenarios.each do |scenario|
          scenario = scenario.to_h.deep_stringify_keys
          raise InvalidDocument, "a scenario in set #{set['key'].inspect} has no key" if scenario["key"].blank?
          raise InvalidDocument, "scenario #{scenario['key'].inspect} has no prompt" if scenario["prompt"].blank?

          scenario["key"] = scenario["key"].to_s
          index = set["scenarios"].index { |existing| existing["key"] == scenario["key"] }
          index ? set["scenarios"][index] = scenario : set["scenarios"] << scenario
        end
      end

      def build_products(documents)
        documents.each_with_index.map do |product, position|
          Product.new(
            key: product["key"],
            name: product["name"].presence || product["key"],
            description: product["description"].presence,
            agent: product["agent"].presence&.to_s,
            metadata: product.except(*PRODUCT_KEYS),
            position: position,
            sets: product["sets"].each_with_index.map { |set, set_position| build_set(set, set_position) }
          )
        end
      end

      def build_set(set, position)
        Set.new(
          key: set["key"],
          name: set["name"].presence || set["key"],
          description: set["description"].presence,
          judge: (set["judge"] || {}).to_h.stringify_keys,
          criteria: Array(set["criteria"]).map { |criterion| criterion.to_h.deep_stringify_keys },
          metadata: set.except(*SET_KEYS),
          position: position,
          scenarios: set["scenarios"].each_with_index.map do |entry, index|
            Scenario.from_hash(entry.merge("position" => index), group: set["key"], group_name: set["name"].presence || set["key"])
          end
        )
      end

      def product_document(product)
        compact({
          "key" => product.key,
          "name" => product.name,
          "description" => product.description,
          "agent" => product.agent,
          "sets" => product.sets.map { |set| set_document(set) }
        }.merge(product.metadata))
      end

      def set_document(set)
        compact({
          "key" => set.key,
          "name" => set.name,
          "description" => set.description,
          "judge" => set.judge,
          "criteria" => set.criteria,
          "scenarios" => set.scenarios.map { |scenario| scenario_document(scenario) }
        }.merge(set.metadata))
      end

      def scenario_document(scenario)
        compact({
          "key" => scenario.key,
          "prompt" => scenario.prompt,
          "expect" => scenario.expectations,
          "notes" => scenario.notes,
          "tags" => scenario.tags,
          "params" => scenario.params,
          "production_only" => (true if scenario.production_only?)
        })
      end

      def compact(hash)
        hash.reject { |_, value| value.nil? || (value.respond_to?(:empty?) && value.empty? && value != false) }
      end
    end
  end
end
