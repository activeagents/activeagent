# frozen_string_literal: true

module ActiveAgent
  module Evals
    # What one run of the agent on one scenario produced — the value the
    # Runner's `replay` callable returns.
    #
    # @!attribute answer
    #   @return [String, nil] the agent's final answer
    # @!attribute tool_calls
    #   @return [Array<Hash>] one hash per call: `"name"`, and optionally
    #     `"arguments"`, `"error"` (true when the tool failed), `"detail"`
    #     (the error or a result preview), `"duration_ms"`
    # @!attribute error
    #   @return [String, nil] the exception when the run raised before answering
    # @!attribute cost
    #   @return [Numeric, nil] estimated spend, when the caller prices tokens
    # @!attribute metadata
    #   @return [Hash] anything the caller wants carried onto the Result (a run id, a chat id)
    Replay = Struct.new(:answer, :tool_calls, :duration_ms, :input_tokens, :output_tokens, :error, :cost, :metadata,
                        keyword_init: true) do
      def initialize(answer: nil, tool_calls: [], duration_ms: nil, input_tokens: nil, output_tokens: nil,
                     error: nil, cost: nil, metadata: {})
        super(
          answer: answer,
          tool_calls: Array(tool_calls).map { |call| call.respond_to?(:to_h) ? call.to_h.stringify_keys : { "name" => call.to_s } },
          duration_ms: duration_ms,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          error: error&.to_s,
          cost: cost,
          metadata: (metadata || {}).to_h
        )
      end

      # Builds a Replay for a run that raised, so a failing scenario is scored
      # and diagnosed like any other rather than aborting the evaluation.
      def self.failed(error, **attributes)
        new(error: error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s, **attributes)
      end

      def errored?
        error.present?
      end

      def tool_names
        tool_calls.map { |call| call["name"].to_s }
      end

      def failed_tool_calls
        tool_calls.select { |call| call["error"] }
      end

      def total_tokens
        input_tokens.to_i + output_tokens.to_i
      end

      def to_h
        super.compact
      end
    end
  end
end
