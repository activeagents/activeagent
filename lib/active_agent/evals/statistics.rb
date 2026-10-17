# frozen_string_literal: true

module ActiveAgent
  module Evals
    # The summary statistics a report computes over its results.
    module Statistics
      module_function

      # Nearest-rank percentile: the value at rank ceil(pct / 100 × n) of the
      # values sorted ascending, so the result is always one of the values. The
      # dashboard's Metrics view uses the same rule (ActionAgent::MetricsReport),
      # so a model's P95 reads the same in both. nil for no values.
      #
      # @param values [Array<Numeric>] in any order; nils are ignored
      # @param pct [Numeric] 0..100
      # @return [Numeric, nil]
      def percentile(values, pct)
        sorted = values.compact.sort
        return nil if sorted.empty?

        rank = (sorted.size * pct / 100.0).ceil
        sorted[rank.clamp(1, sorted.size) - 1]
      end
    end
  end
end
