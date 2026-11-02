# frozen_string_literal: true

module ActiveAgent
  module Evals
    # The bars a suite declares for a run: the score every answer must reach
    # (the Runner's and the Report's threshold), the share of a model's
    # answers that must pass, and the groups whose results are reported but
    # not gated. Report#gates compares each group's pass rate against them.
    #
    #   suite: support_desk
    #   pass:
    #     threshold: 0.7
    #     min_pass_rate: 0.8
    #   groups:
    #     - key: orders
    #       pass: { min_pass_rate: 1.0 }
    #     - key: experimental
    #       pass: { gated: false }
    #
    # A group's `min_pass_rate` falls back to the suite's, and the suite's to
    # DEFAULT_MIN_PASS_RATE; a group is gated unless it says `gated: false`.
    # Layered documents override key by key at both levels, so a document
    # that sets one group's bar leaves the suite's threshold and the other
    # groups alone.
    class PassThresholds
      DEFAULT_MIN_PASS_RATE = 1.0
      SUITE_KEYS = %w[threshold min_pass_rate].freeze
      GROUP_KEYS = %w[min_pass_rate gated].freeze

      # Layers each document's top-level `pass` and each group's `pass`
      # (groups under `groups`, keyed by their `key`), later documents
      # winning key by key. A group without a key has no scenarios to gate,
      # so a `pass` block on one is refused.
      #
      # @param documents [Array<Hash>] parsed YAML documents, base first
      def self.from_documents(documents)
        suite = {}
        groups = {}
        Array(documents).each do |document|
          document = document.to_h.deep_stringify_keys
          suite.merge!(pass_block(document["pass"], "the suite"))
          Array(document["groups"]).each do |group|
            group = group.to_h.deep_stringify_keys
            key = group["key"].to_s
            raise ArgumentError, "\"pass\" of a group without a key gates nothing" if key.empty? && !group["pass"].nil?

            groups[key] = groups.fetch(key, {}).merge(pass_block(group["pass"], "group #{key}"))
          end
        end
        new(suite: suite, groups: groups)
      end

      def self.default
        new
      end

      # A `pass` block as a string-keyed Hash; nothing declared reads as {},
      # and anything but a mapping raises ArgumentError naming `place`.
      def self.pass_block(value, place)
        return {} if value.nil?
        raise ArgumentError, "\"pass\" of #{place} must be a mapping, got #{value.inspect}" unless value.is_a?(Hash)

        value.deep_stringify_keys
      end

      # `pass` as a string-keyed Hash of the `allowed` keys (SUITE_KEYS or
      # GROUP_KEYS), each refusal naming `place` — the suite, a group, or
      # whatever a caller holds a block for: a bar is a number from 0 to 1,
      # kept as a Float so `1` and `1.0` read, serialize and hash the same,
      # and `gated` is true or false.
      def self.validate(pass, allowed, place)
        pass_block(pass, place).to_h do |key, value|
          raise ArgumentError, "unknown key #{key.inspect} in \"pass\" of #{place}; expected one of #{allowed.join(', ')}" unless allowed.include?(key)

          if key == "gated"
            raise ArgumentError, "\"gated\" in \"pass\" of #{place} must be true or false, got #{value.inspect}" unless [ true, false ].include?(value)

            [ key, value ]
          elsif value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
            [ key, value.to_f ]
          else
            raise ArgumentError, "#{key.inspect} in \"pass\" of #{place} must be a number from 0 to 1, got #{value.inspect}"
          end
        end
      end

      # @param suite [Hash] the suite's bars, `threshold` and `min_pass_rate`
      # @param groups [Hash{String=>Hash}] each group's bars by group key,
      #   `min_pass_rate` and `gated`
      def initialize(suite: {}, groups: {})
        @suite = self.class.validate(suite, SUITE_KEYS, "the suite")
        @groups = groups.to_h.deep_stringify_keys.filter_map do |key, pass|
          declared = self.class.validate(pass, GROUP_KEYS, "group #{key}")
          [ key.to_s, declared ] if declared.any?
        end.to_h
      end

      # The score every answer must reach, 0..1.
      def threshold
        (@suite["threshold"] || PASS_THRESHOLD).to_f
      end

      # The share of a model's answers that must pass, 0..1: the group's own
      # bar when it declared one, else the suite's, else DEFAULT_MIN_PASS_RATE.
      def min_pass_rate(group = nil)
        own = @groups.dig(group.to_s, "min_pass_rate") unless group.nil?
        (own || @suite["min_pass_rate"] || DEFAULT_MIN_PASS_RATE).to_f
      end

      # False only for a group that declared `gated: false`; nil and unknown
      # groups are gated.
      def gated?(group)
        return true if group.nil?

        @groups.dig(group.to_s, "gated") != false
      end

      # The bars in effect, with each group's declared keys only.
      def to_h
        {
          "threshold" => threshold,
          "min_pass_rate" => min_pass_rate,
          "groups" => @groups.transform_values(&:dup)
        }
      end

      def ==(other)
        other.is_a?(PassThresholds) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end
    end
  end
end
