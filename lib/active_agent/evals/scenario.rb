# frozen_string_literal: true

module ActiveAgent
  module Evals
    # One task an evaluation replays through the agent: the message a user
    # would send, the group of related tasks it belongs to, and what a passing
    # answer is expected to do.
    #
    # @!attribute key
    #   @return [String] stable within a suite ("history_3"), so results line up across runs
    # @!attribute group
    #   @return [String, nil] the group key ("history")
    # @!attribute group_name
    #   @return [String, nil] the group's display name ("History / audit")
    # @!attribute expected_tools
    #   @return [Array<String>] tool names a passing answer calls (any one of them)
    # @!attribute expected_patterns
    #   @return [Array<String>] substrings or patterns the answer must contain
    # @!attribute forbidden_patterns
    #   @return [Array<String>] substrings or patterns the answer must avoid
    # @!attribute production_only
    #   @return [Boolean] whether a local environment cannot answer with real data
    # @!attribute tags
    #   @return [Array<String>] labels a catalog files the scenario under ("billing")
    # @!attribute params
    #   @return [Hash] free-form parameters a replay may read; kept as written
    # @!attribute metadata
    #   @return [Hash, nil] opaque extension fields from a catalog document
    Scenario = Struct.new(:key, :group, :group_name, :prompt, :expected_tools, :expected_patterns,
                          :forbidden_patterns, :notes, :production_only, :position, :tags, :params, :metadata,
                          keyword_init: true) do
      # Builds a scenario from a hash — ScenarioParser output, a suite entry, or
      # a persisted record's attributes. Expectations are read from an
      # `expectations`/`expect` sub-hash (`tools`, `contains`, `not_contains`)
      # or from those keys at the top level.
      # Pass +metadata+ when extension fields have been separated from a
      # document; its literal `metadata` key may itself be an extension.
      def self.from_hash(attributes, group: nil, group_name: nil, metadata: nil)
        attrs = attributes.to_h.deep_stringify_keys
        expect = (attrs["expectations"] || attrs["expect"] || {}).to_h.stringify_keys
        metadata = attrs["metadata"] if metadata.nil? && attrs["metadata"].is_a?(Hash)

        new(
          key: attrs["key"].to_s,
          group: attrs["group"].presence || group,
          group_name: attrs["group_name"].presence || group_name,
          prompt: attrs.fetch("prompt").to_s.strip,
          expected_tools: list(expect["tools"] || attrs["tools"]),
          expected_patterns: list(expect["contains"] || attrs["contains"]),
          forbidden_patterns: list(expect["not_contains"] || attrs["not_contains"]),
          notes: attrs["notes"].presence,
          production_only: attrs["production_only"] == true,
          position: attrs["position"],
          tags: list(attrs["tags"]),
          params: (attrs["params"] || {}).to_h.deep_stringify_keys,
          metadata: (metadata || {}).to_h.deep_stringify_keys
        )
      end

      def self.list(value)
        Array(value).map(&:to_s).reject(&:blank?)
      end

      def production_only?
        production_only == true
      end

      def expectations
        {
          "tools" => expected_tools,
          "contains" => expected_patterns,
          "not_contains" => forbidden_patterns
        }.reject { |_, value| value.blank? }
      end

      def to_h
        super.compact.reject { |field, value| %i[tags params metadata].include?(field) && value.blank? }
      end
    end

    Scenario::DOCUMENT_KEYS = %w[key prompt expect expectations tools contains not_contains notes tags params production_only position].freeze
  end
end
