# frozen_string_literal: true

module ActiveAgent
  module Evals
    # An evaluation suite read from one or more YAML documents, later documents
    # layered over earlier ones: a scenario with a key already present replaces
    # it, a new key is appended to its group, and a new group is appended to the
    # suite. That is how an app keeps a shared suite and lets a deployment add or
    # reword questions.
    #
    #   suite: assistant_dashboard
    #   description: The V1 question catalog
    #   groups:
    #     - key: find_records
    #       name: Find record(s)
    #       scenarios:
    #         - key: find_records_1
    #           prompt: Which medical search terms are under client control?
    #           expect:
    #             tools: [find_records, count_records]
    #           notes: Uniform locally.
    #           production_only: false
    class Suite
      class NotFound < StandardError; end

      attr_reader :name, :description, :groups

      # Loads the documents at `paths` (missing files are skipped) and raises
      # NotFound when none exist.
      def self.load(*paths, name: nil)
        existing = paths.flatten.map(&:to_s).select { |path| File.exist?(path) }
        raise NotFound, "no evaluation suite at #{paths.flatten.join(', ')}" if existing.empty?

        documents = existing.map { |path| YAML.safe_load_file(path, aliases: true) || {} }
        new(documents, name: name || File.basename(existing.first, ".yml"))
      end

      # @param documents [Array<Hash>] parsed YAML documents, base first
      def initialize(documents, name: nil)
        documents = Array(documents).map(&:deep_stringify_keys)
        @name = documents.filter_map { |doc| doc["suite"] }.last || name
        @description = documents.filter_map { |doc| doc["description"] }.last
        @groups = merge_groups(documents)
      end

      # Scenarios narrowed by group keys, scenario keys, or both; `production_only`
      # scenarios are dropped unless `include_production_only` is true.
      def scenarios(groups: nil, keys: nil, include_production_only: true)
        selected = all_scenarios
        selected = selected.select { |scenario| Array(groups).map(&:to_s).include?(scenario.group) } if groups.present?
        selected = selected.select { |scenario| Array(keys).map(&:to_s).include?(scenario.key) } if keys.present?
        selected = selected.reject(&:production_only?) unless include_production_only
        selected
      end

      def all_scenarios
        @all_scenarios ||= @groups.flat_map do |group|
          group["scenarios"].each_with_index.map do |entry, index|
            Scenario.from_hash(entry.merge("position" => index), group: group["key"], group_name: group["name"])
          end
        end
      end

      def group_keys
        @groups.map { |group| group["key"] }
      end

      def find(key)
        all_scenarios.find { |scenario| scenario.key == key.to_s } ||
          raise(NotFound, "no scenario #{key.inspect} in suite #{name}")
      end

      private

      def merge_groups(documents)
        documents.each_with_object([]) do |document, groups|
          Array(document["groups"]).each do |incoming|
            existing = groups.find { |group| group["key"] == incoming["key"] }

            if existing
              existing["name"] = incoming["name"] if incoming["name"].present?
              existing["description"] = incoming["description"] if incoming["description"].present?
              merge_scenarios(existing, Array(incoming["scenarios"]))
            else
              groups << incoming.merge("scenarios" => Array(incoming["scenarios"]))
            end
          end
        end
      end

      def merge_scenarios(group, incoming)
        incoming.each do |scenario|
          index = group["scenarios"].index { |existing| existing["key"] == scenario["key"] }
          index ? group["scenarios"][index] = scenario : group["scenarios"] << scenario
        end
      end
    end
  end
end
