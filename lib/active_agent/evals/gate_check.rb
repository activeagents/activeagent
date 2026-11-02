# frozen_string_literal: true

module ActiveAgent
  module Evals
    # A report's pass gates as one check with the message a failing
    # assertion prints, so the RSpec matcher (`active_agent/evals/rspec`)
    # and the Minitest assertion (`active_agent/evals/minitest`) fail with
    # the same text: how many gates are not met, each of them as a sentence,
    # then the failures to read under a heading per group.
    #
    #   check = ActiveAgent::Evals::GateCheck.new(report)
    #   check.met?   # => false
    #   puts check.message
    #   # 2 of 5 pass gates not met
    #   # - Order support · gpt-5-mini: 1/2 (50%) passed, below 100%
    #   # - All · gpt-5-mini: 3/4 (75%) passed, below 80%
    #   #
    #   # Order support failures:
    #   # - `order_status` on `gpt-5-mini`: low quality — Scored 50% against a pass threshold of 70%, weakest on response_present (100%).
    class GateCheck
      # @param report [Report] the report whose gates are checked
      # @param thresholds [PassThresholds, nil] the bars to hold the report
      #   to; without them Report#gates decides, taking the report's own,
      #   else the defaults
      def initialize(report, thresholds = nil)
        @report = report
        @bars = [ thresholds ].compact
      end

      # Whether every gate is met.
      def met?
        @report.passed?(*@bars)
      end

      # Every gate, in Report#gates order.
      def gates
        @report.gates(*@bars)
      end

      # The gates that are not met, in gates order.
      def unmet
        gates.reject(&:met?)
      end

      # The text a failing assertion prints. The first line counts the gates
      # not met, or is the one line "every pass gate met" when none is; then
      # each unmet gate as Gate#to_s; then, after a blank line, the failures
      # to read: for each group with an unmet gate, in gates order, "<group>
      # failures:" over Report#failures_markdown for that group. An unmet All
      # row adds the failures it counts, those in gated groups or in no
      # group: under "Failures:" when no group row is unmet, else the ones
      # outside the groups already listed under "Other failures:", when there
      # are any. An ungated group's failures count toward no gate and are
      # never listed.
      def message
        all = gates
        unmet = all.reject(&:met?)
        return "every pass gate met" if unmet.empty?

        lines = [ "#{unmet.size} of #{all.size} pass gates not met", *unmet.map { |gate| "- #{gate}" } ]
        grouped = unmet.reject { |gate| gate.group.nil? }.uniq(&:group)
        grouped.each { |gate| lines << "" << "#{gate.name} failures:" << @report.failures_markdown(group: gate.group) }
        if unmet.any? { |gate| gate.group.nil? }
          ungated = all.reject(&:gated).map(&:group)
          listed = grouped.map(&:group)
          others = @report.failures.reject { |result| (ungated + listed).include?(result.scenario.group) }
          heading = listed.empty? ? "Failures:" : "Other failures:"
          lines << "" << heading << others.map { |result| @report.failure_markdown(result) }.join("\n") if others.any?
        end
        lines.join("\n")
      end
      alias to_s message
    end
  end
end
