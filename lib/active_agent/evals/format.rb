# frozen_string_literal: true

module ActiveAgent
  module Evals
    # How every evaluation surface writes a pass count, a score and a cost, so
    # the HTML report, the Markdown report, a diagnosis and the dashboard read
    # alike:
    #
    #   - a pass/fail fraction carries its percentage: "14/16 · 88%" (in
    #     Markdown "14/16 (88%)"); nothing scored (0/0) reads "—"
    #   - a 0..1 score — a mean score, a criterion score, task completion, a
    #     judge's confidence, the pass threshold — reads as a whole percent:
    #     "93%", "pass ≥ 70%"
    #   - money has four decimals, six below $0.001, "$0.00" for an explicit
    #     zero, and a leading "~" when any part of it was estimated from
    #     tokens × model rates rather than reported; LEGEND explains the mark
    #
    # Percentages round half up to a whole number. Stored values stay 0..1
    # and USD; only their display changes here. The dashboard's
    # actionagent/frontend/utils/evalFormat.mjs is the JavaScript copy of
    # these rules, so a change here needs the same change there.
    module Format
      EMPTY = "—"
      # Shown once per surface where a "~" figure is visible.
      LEGEND = "~ estimated from tokens × model rates"
      # Rate sources that are a guess at the model's price rather than a
      # catalog entry for it (see the dashboard's ModelPricing).
      FALLBACK_RATE_SOURCES = %w[pattern default].freeze

      module_function

      # 0.875 → "88%". "—" for a missing value.
      def percent(fraction)
        return EMPTY unless finite?(fraction)

        "#{whole(fraction.to_f * 100)}%"
      end

      # 14 of 16 → "14/16 · 88%", or "14/16 (88%)" with `style: :markdown`,
      # where " · " would read as a table cell separator next to a pipe.
      # "—" when nothing was scored.
      def passes(passed, total, style: :text)
        count = total.to_i
        return EMPTY unless count.positive?

        done = passed.to_i
        pct = "#{whole(done * 100.0 / count)}%"
        style == :markdown ? "#{done}/#{count} (#{pct})" : "#{done}/#{count} · #{pct}"
      end

      # A 0..1 score as a percent: 0.93 → "93%".
      def score(value)
        percent(value)
      end

      # 0.7 → "pass ≥ 70%".
      def threshold(value)
        "pass ≥ #{percent(value)}"
      end

      # 0.0243 → "$0.0243", 0.000697 → "$0.000697", 0 → "$0.00"; with
      # `estimated`, "~$0.0243". "—" for a missing value.
      def money(value, estimated: false)
        return EMPTY unless finite?(value)

        amount = value.to_f
        digits = if amount.zero? then 2
        elsif amount.abs < 0.001 then 6
        else 4
        end
        "#{'~' if estimated}$#{format("%.#{digits}f", amount)}"
      end

      # A $/M token rate with at least two decimals and no trailing noise:
      # 5 → "$5.00/M", 0.075 → "$0.075/M".
      def per_million(rate)
        whole, fraction = format("%.4f", rate.to_f).split(".")
        fraction = fraction.sub(/0+\z/, "")
        "$#{whole}.#{fraction.ljust(2, '0')}/M"
      end

      # The tooltip of an estimated figure: how it was worked out, e.g.
      # "estimated: 2,328 in × $5.00/M + 423 out × $30.00/M · catalog rate".
      # `rate` is `{ "input", "output", "source" }` in $ per million tokens;
      # a rate from the name-pattern table or the default appends
      # "(fallback rate)". Without a rate it names the method only.
      def cost_title(input_tokens: nil, output_tokens: nil, rate: nil)
        rate = rate.to_h.transform_keys(&:to_s) if rate.respond_to?(:to_h)
        return "estimated from tokens × model rates" unless rate.is_a?(Hash) && finite?(rate["input"]) && finite?(rate["output"])

        source = rate["source"].presence || "catalog"
        title = "estimated: #{delimited(input_tokens)} in × #{per_million(rate['input'])} + " \
                "#{delimited(output_tokens)} out × #{per_million(rate['output'])} · #{source} rate"
        title += " (fallback rate)" if FALLBACK_RATE_SOURCES.include?(source.to_s)
        title
      end

      # Half up, on the decimal value: 14.5 → 15, even when the float arrived
      # as 14.499999999999998.
      def whole(value)
        value.to_f.round(9).round
      end

      def delimited(count)
        count.to_i.to_s.gsub(/(\d)(?=(\d{3})+\z)/, '\1,')
      end

      def finite?(value)
        return false if value.nil? || value == ""

        Float(value, exception: false)&.finite? || false
      end
    end
  end
end
