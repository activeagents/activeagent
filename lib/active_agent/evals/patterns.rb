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
      MONTHS = %w[january february march april may june july august september october november december].freeze

      # `text` as a pattern that matches it in any case, each letter a
      # character class: any_case("Oct.") is "[Oo][Cc][Tt]\\.".
      def self.any_case(text)
        text.chars.map { |char| char.match?(/[a-z]/i) ? "[#{char.upcase}#{char.downcase}]" : Regexp.escape(char) }.join
      end
      private_class_method :any_case

      # A day of the month written beside its month, in any case: "Oct 12",
      # "Sept. 12" and "October 12" before the figure, "12 Oct" and "12th of
      # October" after it. A lookbehind takes alternatives of one length only,
      # so the spellings before the figure are one lookbehind per length, and
      # each letter in it is a character class rather than `(?i:...)`: the
      # dashes make the pattern UTF-8, where case folding lets "st" match the
      # one-character ligature "ﬆ", and Ruby 3.2 refuses a lookbehind whose
      # length that leaves open. "may" is left out after the figure, where it
      # is usually the verb.
      MONTH_BEFORE = MONTHS.flat_map { |month| [ month, month[0, 3], "#{month[0, 3]}." ] }.push("sept", "sept.").uniq
        .group_by(&:length).sort.map { |_length, spellings| "(?<!#{spellings.map { |spelling| "\\b#{any_case("#{spelling} ")}" }.join('|')})" }
        .join.freeze
      MONTH_AFTER = (MONTHS - %w[may]).map { |month| "#{month[0, 3]}(?:#{Regexp.escape(month[3..])})?" }.push("sept").join("|").freeze

      module_function

      # The integer `count` as a figure on its own: number(10) matches
      # "10 sessions", "(10)" and "10." at a sentence end, not "2026-10-01",
      # "10/1", "10:00", "1-10" or "1–10", "110", "10.5", "10,000", "10%",
      # "Oct 10" or "10 October". A ratio such as "10/22" does not match
      # either, because "10/12" reads as a date as often as a count; expect
      # "10 of 22". `count` is read as a whole number from its text, so 3 and
      # "3" work and 1.5, 10.0, "a" or a negative count raise ArgumentError.
      def number(count)
        count = whole_number(count, "count")
        "(?<![\\d/:.,\\-\u2013\u2014])#{MONTH_BEFORE}\\b#{count}\\b(?![/:\\-\u2013\u2014])(?![.,]\\d)(?! ?%)" \
          "(?!(?i:(?:st|nd|rd|th)?,? (?:of )?(?:#{MONTH_AFTER})\\b))"
      end

      # `count` of `total` as a percentage, whole or to one or two decimals,
      # with an optional space before the sign: share(3, 4) matches "75%",
      # "75 %", "75.0%" and "75.00%", not "175%", "7.5%", "75.5%" or "0.75".
      # The whole percent rounds half up like Format.whole and the decimals
      # like Float#round, so share(1, 8) matches "13%", "12.5%" and "12.50%",
      # and share(12, 22) matches "55%", "54.5%" and "54.55%". Both arguments are read like
      # `number`'s; a total below one and a count above the total raise
      # ArgumentError.
      def share(count, total)
        count = whole_number(count, "count")
        total = whole_number(total, "total", minimum: 1)
        raise ArgumentError, "count must not exceed total" if count > total

        percent = count * 100.0 / total
        decimals = [ 2, 1 ].map { |places| Regexp.escape(format("%.#{places}f", percent.round(places))) }
        "(?<![\\d.,])\\b(?:#{decimals.join('|')}|#{Format.whole(percent)}) ?%"
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
