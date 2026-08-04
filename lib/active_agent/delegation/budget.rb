# frozen_string_literal: true

module ActiveAgent
  module Delegation
    # Cost and latency limits for delegated work.
    #
    # A sub-agent is a loop inside a loop: the parent model decides how often
    # to call it, and each call spends tokens and wall-clock time nobody
    # explicitly authorized. A budget puts a ceiling on that — per delegation
    # and across the agent as a whole — so a runaway hand-off degrades into a
    # bounded answer instead of an unbounded bill.
    #
    # Every limit is optional; an empty budget imposes nothing.
    #
    # @example Per delegation
    #   delegate_to SummarizerAgent, budget: { max_calls: 3, max_tokens: 8_000, timeout: 20 }
    #
    # @example Across every delegation this agent makes
    #   delegation_budget max_calls: 10, max_duration: 60, max_cost: 0.25,
    #                     rates: { input: 0.15, output: 0.60 }
    class Budget
      # What to do when a limit is reached.
      #
      # +:stop+  — return a structured "budget exhausted" result to the calling
      #            model so it can finish with what it already has (default).
      # +:raise+ — raise {BudgetExceededError} and abort the generation.
      POLICIES = %i[stop raise].freeze

      LIMITS = %i[max_calls max_tokens max_cost max_duration].freeze
      KEYS   = (LIMITS + %i[timeout rates on_exceeded]).freeze

      # A limit that has been reached.
      Violation = Struct.new(:limit, :allowed, :used, keyword_init: true) do
        # @return [String] wording aimed at the calling model, not at a developer
        def message
          "Delegation budget exhausted (#{limit}: #{format_number(used)} of #{format_number(allowed)} used). " \
            "Do not retry this tool; answer with the information you already have."
        end

        private

        def format_number(value)
          value.is_a?(Float) ? value.round(6) : value
        end
      end

      # @return [Integer, nil] maximum number of delegated calls
      attr_reader :max_calls
      # @return [Integer, nil] maximum cumulative tokens across delegated calls
      attr_reader :max_tokens
      # @return [Float, nil] maximum cumulative spend in USD
      attr_reader :max_cost
      # @return [Float, nil] maximum cumulative wall-clock seconds
      attr_reader :max_duration
      # @return [Float, nil] per-call wall-clock timeout in seconds
      attr_reader :timeout
      # @return [Hash, nil] inline token rates in USD per 1M tokens
      attr_reader :rates
      # @return [Symbol, nil] :stop or :raise
      attr_reader :on_exceeded

      # Coerces a budget spec into a Budget.
      #
      # @param spec [Budget, Hash, nil]
      # @return [Budget]
      # @raise [ArgumentError] on unknown keys or an invalid policy
      def self.build(spec = nil)
        case spec
        when Budget then spec
        when nil    then new
        when Hash   then new(**spec.symbolize_keys)
        else
          raise ArgumentError, "Delegation budget must be a Hash or #{name}, got #{spec.inspect}"
        end
      end

      def initialize(**options)
        unknown = options.keys - KEYS
        raise ArgumentError, "Unknown delegation budget keys: #{unknown.join(", ")}. Valid keys: #{KEYS.join(", ")}" if unknown.any?

        @max_calls    = options[:max_calls]
        @max_tokens   = options[:max_tokens]
        @max_cost     = options[:max_cost]
        @max_duration = options[:max_duration]
        @timeout      = options[:timeout]
        @rates        = options[:rates]
        @on_exceeded  = options[:on_exceeded]&.to_sym

        if @on_exceeded && !POLICIES.include?(@on_exceeded)
          raise ArgumentError, "Unknown delegation budget policy #{@on_exceeded.inspect}. Valid policies: #{POLICIES.join(", ")}"
        end
      end

      # Returns a budget where +other+'s settings win over this one's.
      #
      # @param other [Budget, nil]
      # @return [Budget]
      def merge(other)
        return self if other.nil?

        self.class.new(**to_h.merge(other.to_h))
      end

      # @return [Boolean] whether any limit is set
      def limited?
        LIMITS.any? { |limit| public_send(limit) }
      end

      # @return [Symbol] the effective policy
      def policy
        on_exceeded || :stop
      end

      # Finds the first limit the ledger has already reached.
      #
      # Limits are checked *before* a call runs, because token spend can only
      # be measured after the fact. A budget of +max_tokens: 8_000+ therefore
      # means "stop delegating once 8,000 tokens have been spent", not "never
      # exceed 8,000 tokens".
      #
      # @param ledger [Ledger]
      # @return [Violation, nil]
      def violation_for(ledger)
        return Violation.new(limit: :max_calls,    allowed: max_calls,    used: ledger.calls)    if max_calls    && ledger.calls    >= max_calls
        return Violation.new(limit: :max_tokens,   allowed: max_tokens,   used: ledger.tokens)   if max_tokens   && ledger.tokens   >= max_tokens
        return Violation.new(limit: :max_cost,     allowed: max_cost,     used: ledger.cost)     if max_cost     && ledger.cost     >= max_cost
        return Violation.new(limit: :max_duration, allowed: max_duration, used: ledger.duration) if max_duration && ledger.duration >= max_duration

        nil
      end

      # @return [Hash] only the settings that were actually provided
      def to_h
        KEYS.index_with { |key| public_send(key) }.compact
      end
    end
  end
end
