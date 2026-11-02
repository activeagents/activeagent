# frozen_string_literal: true

module ActiveAgent
  module Evals
    # Regexes for a figure an answer is expected to state, built from the data
    # the scenario was seeded with: a count ("3 of 4 tickets") or a share of
    # a total ("75%"). Each is a String that drops into a suite's
    # `expect.contains` / `not_contains` or a `contains` criterion, which
    # Scorer.matches_pattern? tries as a substring and then as a regex:
    #
    #   "expect" => { "contains" => [ Patterns.number(3), Patterns.share(3, 4) ] }
    module Patterns
      module_function

      # The integer `count` as a figure on its own: number(10) matches
      # "10 sessions", "(10)" and "10." at a sentence end, not "2026-10-01",
      # "10:00", "1-10", "110", "10.5", "10,000" or "10%". `count` is read as
      # a whole number from its text, so 3 and "3" work and 1.5, 10.0, "a" or
      # a negative count raise ArgumentError.
      def number(count)
        count = whole_number(count, "count")
        "(?<![\\d/:.,-])\\b#{count}\\b(?![/:-])(?![.,]\\d)(?! ?%)"
      end

      # `count` of `total` as a percentage, whole or to one decimal, with an
      # optional space before the sign: share(3, 4) matches "75%", "75 %" and
      # "75.0%", not "175%", "7.5%", "75.5%" or "0.75". The whole percent
      # rounds half up like Format.whole and the decimal like Float#round(1),
      # so share(1, 8) matches "13%" and "12.5%". Both arguments are read like
      # `number`'s; a total below one and a count above the total raise
      # ArgumentError.
      def share(count, total)
        count = whole_number(count, "count")
        total = whole_number(total, "total", minimum: 1)
        raise ArgumentError, "count must not exceed total" if count > total

        percent = count * 100.0 / total
        decimal = format("%.1f", percent.round(1))
        "(?<![\\d.,])\\b(?:#{Regexp.escape(decimal)}|#{Format.whole(percent)}) ?%"
      end

      # `value` as an Integer of at least `minimum`, read from its text so
      # that 1.5 is rejected rather than truncated: 3 and "3" → 3; 1.5, "a"
      # and a value below `minimum` raise ArgumentError.
      def whole_number(value, name, minimum: 0)
        number = Integer(value.to_s, 10)
        raise ArgumentError, "#{name} must be #{minimum.positive? ? 'positive' : 'zero or positive'}" if number < minimum

        number
      end
    end
  end
end
