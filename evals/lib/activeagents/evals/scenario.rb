# frozen_string_literal: true

module ActiveAgents
  module Evals
    # One task an evaluation replays through the agent: the message a user
    # would send, the group of related tasks it belongs to, and what a passing
    # answer is expected to do.
    #
    # @!attribute key
    #   @return [String] stable within a suite ("blame_3"), so results line up across runs
    # @!attribute group
    #   @return [String, nil] the group key ("blame")
    # @!attribute group_name
    #   @return [String, nil] the group's display name ("Blame / audit")
    # @!attribute expected_tools
    #   @return [Array<String>] tool names a passing answer calls (any one of them)
    # @!attribute expected_patterns
    #   @return [Array<String>] substrings or patterns the answer must contain
    # @!attribute forbidden_patterns
    #   @return [Array<String>] substrings or patterns the answer must avoid
    # @!attribute production_only
    #   @return [Boolean] whether a local environment cannot answer with real data
    Scenario = Struct.new(:key, :group, :group_name, :prompt, :expected_tools, :expected_patterns,
                          :forbidden_patterns, :notes, :production_only, :position, keyword_init: true) do
      # Builds a scenario from a hash — ScenarioParser output, a suite entry, or
      # a persisted record's attributes. Expectations are read from an
      # `expectations`/`expect` sub-hash (`tools`, `contains`, `not_contains`)
      # or from those keys at the top level.
      def self.from_hash(attributes, group: nil, group_name: nil)
        attrs = attributes.to_h.deep_stringify_keys
        expect = (attrs["expectations"] || attrs["expect"] || {}).to_h.stringify_keys

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
          position: attrs["position"]
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
        super.compact
      end
    end
  end
end
