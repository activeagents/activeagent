# frozen_string_literal: true

module ActiveAgent
  module Evals
    # Scores one Replay against an evaluation's criteria and the scenario's
    # expectations. Returns `criterion key => 0.0..1.0`, with nil for a
    # criterion that could not be scored (an llm_judge criterion with no judge).
    #
    # Criteria are `{ "key", "type", "config" }` hashes:
    #
    #   response_present  — the answer is non-empty
    #   min_length        — `config.chars` characters (partial credit below)
    #   max_latency_ms    — `config.ms` budget (partial credit above)
    #   token_budget      — `config.output_tokens` budget (partial credit above)
    #   contains          — `config.pattern` (a substring, or a regex) is present
    #   not_contains      — `config.pattern` is absent
    #   llm_judge         — the judge scores the answer against `config.prompt`
    #
    # The scenario's own expectations add `expected_tools`, `expected_content`,
    # `forbidden_content` (when declared) and `tools_succeeded` (when any tool
    # was called).
    class Scorer
      RULE_CRITERION_TYPES = %w[response_present min_length max_latency_ms token_budget contains not_contains].freeze
      CRITERION_TYPES = (RULE_CRITERION_TYPES + %w[llm_judge]).freeze

      attr_reader :criteria, :judge

      def initialize(criteria: [], judge: nil)
        @criteria = Array(criteria).map { |criterion| criterion.to_h.deep_stringify_keys }
        @judge = judge
      end

      def score(scenario, replay)
        scores = {}
        answer = replay.answer.to_s

        @criteria.each do |criterion|
          scores[criterion["key"]] = answer.present? ? score_criterion(criterion, scenario, replay) : 0.0
        end

        if scenario.expected_tools.any?
          scores["expected_tools"] = (scenario.expected_tools & replay.tool_names).any? ? 1.0 : 0.0
        end
        if scenario.expected_patterns.any?
          hits = scenario.expected_patterns.count { |pattern| self.class.matches_pattern?(answer, pattern) }
          scores["expected_content"] = (hits.to_f / scenario.expected_patterns.size).round(3)
        end
        if scenario.forbidden_patterns.any?
          hit = scenario.forbidden_patterns.any? { |pattern| self.class.matches_pattern?(answer, pattern) }
          scores["forbidden_content"] = hit ? 0.0 : 1.0
        end
        # A tool that ran without erroring is evidence only when it is one the
        # scenario expected: a wrong tool that succeeded used to outscore
        # calling nothing at all.
        if replay.tool_calls.any? && (scenario.expected_tools.empty? || (scenario.expected_tools & replay.tool_names).any?)
          scores["tools_succeeded"] = replay.failed_tool_calls.any? ? 0.0 : 1.0
        end

        scores
      end

      # The mean of the scored criteria, or nil when nothing could be scored.
      def self.mean(scores)
        scored = scores.values.compact
        return nil if scored.empty?

        (scored.sum / scored.size).round(3)
      end

      # How long one pattern may take to match one answer. Patterns are
      # whatever the scenario's author typed, and a pathological one must not
      # stall the evaluation.
      PATTERN_TIMEOUT = 1.0

      # Whether `pattern` occurs in `text`: as a plain substring, case
      # insensitively, or else as a regex. A pattern that is not a valid
      # regex, or that takes longer than PATTERN_TIMEOUT, only counts as a
      # substring.
      def self.matches_pattern?(text, pattern)
        pattern = pattern.to_s
        return false if pattern.blank?

        text = text.to_s
        return true if text.downcase.include?(pattern.downcase)

        text.match?(Regexp.new(pattern, Regexp::IGNORECASE, timeout: PATTERN_TIMEOUT))
      rescue RegexpError
        false
      end

      private

      def score_criterion(criterion, scenario, replay)
        config = criterion["config"] || {}
        answer = replay.answer.to_s

        case criterion["type"]
        when "response_present"
          answer.present? ? 1.0 : 0.0
        when "min_length"
          min = config.fetch("chars", 40).to_i
          [ answer.length.to_f / [ min, 1 ].max, 1.0 ].min
        when "max_latency_ms"
          budget = config.fetch("ms", 5_000).to_f
          duration = replay.duration_ms.to_f
          duration.zero? || duration <= budget ? 1.0 : [ budget / duration, 1.0 ].min
        when "token_budget"
          budget = config.fetch("output_tokens", 1_000).to_f
          tokens = replay.output_tokens.to_f
          tokens <= budget ? 1.0 : [ budget / tokens, 1.0 ].min
        when "contains"
          self.class.matches_pattern?(answer, config["pattern"]) ? 1.0 : 0.0
        when "not_contains"
          self.class.matches_pattern?(answer, config["pattern"]) ? 0.0 : 1.0
        when "llm_judge"
          @judge&.score_criterion(criterion: criterion, prompt: scenario.prompt, answer: answer)
        end
      end
    end
  end
end
