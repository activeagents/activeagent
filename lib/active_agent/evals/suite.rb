# frozen_string_literal: true

module ActiveAgent
  module Evals
    # An evaluation suite read from one or more YAML documents, later documents
    # layered over earlier ones: a scenario with a key already present replaces
    # it, a new key is appended to its group, and a new group is appended to the
    # suite. That is how an app keeps a shared suite and lets a deployment add or
    # reword questions. Named criteria lists layer the same way by criterion
    # key, and `criteria("shared", "terse")` hands the chosen lists to
    # Runner.new(criteria:).
    #
    #   suite: support_desk
    #   description: Questions the support team asks every week
    #   criteria:
    #     shared:
    #       - key: cites_order
    #         type: contains
    #         config: { pattern: "ABC-" }
    #     terse:
    #       - key: short
    #         type: min_length
    #         config: { chars: 20 }
    #   groups:
    #     - key: open_tickets
    #       name: Open tickets
    #       scenarios:
    #         - key: open_tickets_1
    #           prompt: Which open tickets mention a refund?
    #           expect:
    #             tools: [find_tickets, count_tickets]
    #           notes: The sample data has three.
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
        @criteria_lists = merge_criteria_lists(documents)
      end

      # The names of the suite's criteria lists, in document order.
      def criteria_names
        @criteria_lists.keys
      end

      # The criteria of the named lists in the order given, a name given twice
      # contributing once, or of every list when no names are given. A
      # criterion whose key an earlier list already holds replaces it in
      # place, so an audience's list can restate a shared criterion with its
      # own bar and the answer is scored on it once. A name no document
      # declared contributes nothing, so a caller can ask for "shared" plus an
      # audience that has no list of its own, and a nil or blank name is
      # skipped, so an audience left unset narrows nothing. The result is
      # ready for Runner.new(criteria:).
      def criteria(*names)
        names = names.flatten.filter_map { |list_name| list_name.to_s.presence }.uniq
        names = criteria_names if names.empty?
        names.each_with_object([]) do |list_name, chosen|
          @criteria_lists.fetch(list_name, []).each do |criterion|
            index = chosen.index { |existing| existing["key"] == criterion["key"] }
            index ? chosen[index] = criterion : chosen << criterion
          end
        end
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
            Scenario.from_hash(entry.merge("position" => index), group: group["key"], group_name: group["name"],
              metadata: entry.except(*Scenario::DOCUMENT_KEYS, "group", "group_name"))
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

      # Each document's criteria lists layered over the earlier ones by name
      # and, within a name, by criterion key.
      def merge_criteria_lists(documents)
        documents.each_with_object({}) do |document, lists|
          criteria_lists(document).each do |list_name, incoming|
            list = (lists[list_name] ||= [])
            incoming.each do |criterion|
              index = list.index { |existing| existing["key"] == criterion["key"] }
              index ? list[index] = criterion : list << criterion
            end
          end
        end
      end

      # A document's `criteria` as `name => list`; a bare list is the one list
      # named "default", and an empty one declares no list.
      def criteria_lists(document)
        value = document["criteria"]
        return {} if value.nil? || value == []

        value = { "default" => value } if value.is_a?(Array)
        raise ArgumentError, "the criteria of suite #{name.inspect} are not a list or a mapping of lists" unless value.is_a?(Hash)

        value.to_h do |list_name, list|
          raise ArgumentError, "criteria list #{list_name.inspect} of suite #{name.inspect} is not a list" unless list.is_a?(Array)

          [ list_name.to_s, list.map { |criterion| normalize_criterion(criterion, list_name) } ]
        end
      end

      def normalize_criterion(criterion, list_name)
        raise ArgumentError, "a criterion in list #{list_name.inspect} of suite #{name.inspect} is not a mapping" unless criterion.is_a?(Hash)
        raise ArgumentError, "a criterion in list #{list_name.inspect} of suite #{name.inspect} has no key" if criterion["key"].blank?

        criterion.merge("key" => criterion["key"].to_s)
      end
    end
  end
end
