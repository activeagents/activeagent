# frozen_string_literal: true

module ActiveAgent
  module Evals
    # Whether the gap between the models of a run is larger than the noise of
    # its scenario sample: each model's pass rate with a confidence interval,
    # and an interval for the difference between every pair of models.
    #
    # The scenario is the unit. A model's pass rate is the mean over its
    # scenarios of the share of its results there that passed (1.0 or 0.0
    # for one result per scenario), and the intervals come from resampling
    # whole scenarios with replacement, +resamples+ times: the percentile
    # bootstrap. A pair is compared on the scenarios both models ran, each
    # resample drawing the same scenarios for both (a paired bootstrap of
    # the per-scenario differences). A pair is decisive when its interval
    # excludes zero.
    #
    # The resampling is seeded, so the same results always give the same
    # intervals and a report renders the same page each time.
    #
    #   comparison = Comparison.new(results: report.results, models: report.models)
    #   comparison.to_h["pairs"].first
    #   # => { "models" => ["gpt-5-mini", "qwen3:8b"], "scenarios" => 42, "difference" => 7.1,
    #   #      "interval" => [0.0, 16.7], "decisive" => false }
    #   comparison.conclusion
    #   # => "The pairwise difference interval includes zero: the ranking is not decisive evidence of superiority."
    class Comparison
      RESAMPLES = 5_000
      CONFIDENCE = 0.95
      SEED = 0
      # Fewer scenarios than this give no interval: resampling one scenario
      # only ever draws that scenario.
      MINIMUM_SCENARIOS = 2

      attr_reader :resamples, :confidence, :seed

      # @param results [Array<Result>]
      # @param models [Array<ModelSpec>] in the run's order, which breaks ties in the ranking
      # @param resamples [Integer]
      # @param confidence [Float] 0..1
      # @param seed [Integer]
      def initialize(results:, models:, resamples: RESAMPLES, confidence: CONFIDENCE, seed: SEED)
        @labels = models.map(&:label)
        @resamples = resamples
        @confidence = confidence
        @seed = seed
        @outcomes = @labels.to_h do |label|
          by_scenario = results.select { |result| result.label == label }.group_by { |result| result.scenario.key }
          [ label, by_scenario.transform_values { |cohort| cohort.count(&:passed?).fdiv(cohort.size) } ]
        end
      end

      # Per model label, in the run's order: `{ "scenarios", "pass_rate",
      # "interval" }`, the pass rate and its interval in percent. The interval
      # is nil below MINIMUM_SCENARIOS, and the pass rate nil for none.
      def models
        @models ||= @labels.to_h do |label|
          values = @outcomes[label].values
          [ label, {
            "scenarios" => values.size,
            "pass_rate" => percent(mean(values)),
            "interval" => interval(values)
          } ]
        end
      end

      # The labels by pass rate, best first; ties keep the run's order.
      def ranking
        @ranking ||= @labels.sort_by.with_index { |label, index| [ -(models[label]["pass_rate"] || -1), index ] }
      end

      # One entry per pair of models, the better ranked first: `{ "models" =>
      # [a, b], "scenarios", "difference", "interval", "decisive" }`, where
      # "difference" is a's pass rate minus b's over the scenarios both ran,
      # in percentage points.
      def pairs
        @pairs ||= ranking.combination(2).map do |a, b|
          shared = @outcomes[a].keys & @outcomes[b].keys
          differences = shared.map { |key| @outcomes[a][key] - @outcomes[b][key] }
          range = interval(differences)

          {
            "models" => [ a, b ],
            "scenarios" => shared.size,
            "difference" => percent(mean(differences)),
            "interval" => range,
            "decisive" => !range.nil? && (range.first.positive? || range.last.negative?)
          }
        end
      end

      # The honest read of the ranking, in a sentence: which pairs differ by
      # more than the noise, or that none does. nil for a single model.
      def conclusion
        return nil if pairs.empty?

        compared, too_few = pairs.partition { |pair| pair["interval"] }
        decisive, inconclusive = compared.partition { |pair| pair["decisive"] }
        sentences =
          if compared.empty?
            [ "The models share too few scenarios to compare." ]
          elsif decisive.empty?
            [ "#{all_include_zero(compared.size)}: the ranking is not decisive evidence of superiority." ]
          else
            decisive.map { |pair| decisive_sentence(pair) } + (inconclusive.any? ? [ others_include_zero(inconclusive.size) ] : [])
          end
        sentences << "#{plural(too_few.size, 'pair')} share#{'s' if too_few.one?} too few scenarios to compare." if compared.any? && too_few.any?
        sentences.join(" ")
      end

      # How the intervals were computed, for a caption.
      def method_summary
        { "statistic" => "pass rate", "interval" => "percentile bootstrap", "unit" => "scenario",
          "resamples" => @resamples, "confidence" => @confidence, "seed" => @seed }
      end

      def to_h
        { "method" => method_summary, "models" => models, "ranking" => ranking, "pairs" => pairs, "conclusion" => conclusion }
      end

      private

      # The bootstrap interval of the mean of +values+, in percent, or nil
      # below MINIMUM_SCENARIOS.
      def interval(values)
        return nil if values.size < MINIMUM_SCENARIOS

        random = Random.new(@seed)
        size = values.size
        means = Array.new(@resamples) do
          sum = 0.0
          size.times { sum += values[random.rand(size)] }
          sum / size
        end
        # A rational tail, so 95% leaves exactly 2.5: in floating point it
        # is 2.5000000000000022, whose nearest rank is one too high.
        tail = (1 - @confidence.rationalize) / 2 * 100
        [ percent(Statistics.percentile(means, tail)), percent(Statistics.percentile(means, 100 - tail)) ]
      end

      def mean(values)
        values.sum.fdiv(values.size) if values.any?
      end

      def percent(fraction)
        (fraction * 100).round(1) if fraction
      end

      def all_include_zero(count)
        count == 1 ? "The pairwise difference interval includes zero" : "All #{count} pairwise difference intervals include zero"
      end

      def others_include_zero(count)
        count == 1 ? "The other pairwise interval includes zero." : "The other #{count} pairwise intervals include zero."
      end

      def decisive_sentence(pair)
        better, worse = pair["difference"].positive? ? pair["models"] : pair["models"].reverse
        low, high = pair["interval"].map(&:abs).sort
        "#{better} passes more scenarios than #{worse}, by #{pair['difference'].abs} points " \
          "(#{(@confidence * 100).round}% CI #{low} to #{high})."
      end

      def plural(count, word)
        "#{count} #{word}#{'s' unless count == 1}"
      end
    end
  end
end
