# frozen_string_literal: true

module ActiveAgent
  module Delegation
    # Running tally of what delegated work has consumed.
    #
    # One ledger is kept per delegation plus one for the agent as a whole, and
    # both live on the agent instance — which is created fresh for every
    # generation. A budget is therefore scoped to a single generation and its
    # entire tool loop, with no cross-request bleed and nothing to reset.
    #
    # @example Inspecting spend after a generation
    #   agent = ResearchAgent.new
    #   agent.process(:research, topic: "hydrogen storage")
    #   agent.process_prompt
    #   agent.delegation_ledger.to_h
    #   #=> { calls: 2, tokens: 1_840, cost: 0.0004, duration: 3.1 }
    class Ledger
      # @return [Integer] delegated calls completed
      attr_reader :calls
      # @return [Integer] cumulative total tokens
      attr_reader :tokens
      # @return [Float] cumulative USD spend (0.0 when no rates are known)
      attr_reader :cost
      # @return [Float] cumulative wall-clock seconds
      attr_reader :duration

      def initialize
        @calls    = 0
        @tokens   = 0
        @cost     = 0.0
        @duration = 0.0
      end

      # Records one delegated call.
      #
      # @param tokens [Integer, nil]
      # @param cost [Float, nil] nil when the model's rates are unknown
      # @param duration [Float] seconds
      # @return [self]
      def record(tokens: 0, cost: nil, duration: 0.0)
        @calls    += 1
        @tokens   += tokens.to_i
        @cost     += cost.to_f
        @duration += duration.to_f

        self
      end

      # @return [Hash]
      def to_h
        { calls: calls, tokens: tokens, cost: cost, duration: duration }
      end
    end
  end
end
