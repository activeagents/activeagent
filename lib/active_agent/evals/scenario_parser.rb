# frozen_string_literal: true

module ActiveAgent
  module Evals
    # Turns a pasted list of user messages into scenario attributes. Accepts the
    # shapes people actually paste:
    #
    #   - one message per line, with or without list markers (`-`, `*`, `1.`)
    #   - `# Heading` or `**Heading**` lines, which start a group; so does a
    #     short unmarked line ending in a colon (`Find records:`)
    #   - a message in backticks at the start of the line, followed by notes,
    #     as in an issue's question catalog:
    #     `` 3. `Show me all providers with no license on file` — 1,060 locally ``
    #   - trailing ` | tools: a, b | contains: x | not_contains: y | key: k`
    #     options on a line
    #   - a JSON array of strings, or of objects with `prompt` (or `message`),
    #     `group`, `key`, `notes`, `tools`, `contains`, `not_contains`
    #
    # Every scenario gets a key unique within the paste, derived from its group
    # and position ("blame_3"), unless the line names one. The result is an
    # array of string-keyed hashes; `Scenario.from_hash` builds the structs.
    class ScenarioParser
      LIST_MARKER = /\A\s*(?:[-*•]|\d+[.)])\s+/
      HEADING = /\A\s*#+\s+(.+?)\s*\z/
      BOLD_HEADING = /\A\s*\*\*(.+?)\*\*:?\s*(?:—.*)?\z/
      # Only a backticked span that opens the line is the prompt; a message
      # that merely mentions `some_tool` is kept whole.
      BACKTICK_PROMPT = /\A`([^`]+)`/
      OPTION_KEYS = %w[tools contains not_contains key group notes].freeze

      def self.parse(text)
        new(text).parse
      end

      # Parses and builds Scenario structs in one step.
      def self.scenarios(text)
        parse(text).map { |attrs| Scenario.from_hash(attrs) }
      end

      def initialize(text)
        @text = text.to_s
      end

      # @return [Array<Hash>] scenario attributes with string keys
      def parse
        stripped = @text.strip
        return [] if stripped.empty?

        scenarios = json?(stripped) ? parse_json(stripped) : parse_lines(stripped)
        assign_keys(scenarios)
      end

      private

      def json?(text)
        text.start_with?("[", "{")
      end

      def parse_json(text)
        parsed = JSON.parse(text)
        parsed = parsed["scenarios"] if parsed.is_a?(Hash) && parsed.key?("scenarios")
        parsed = [ parsed ] if parsed.is_a?(Hash)

        Array(parsed).filter_map do |entry|
          case entry
          when String then scenario(prompt: entry)
          when Hash then scenario_from_hash(entry)
          end
        end
      rescue JSON::ParserError
        parse_lines(text)
      end

      def scenario_from_hash(entry)
        entry = entry.stringify_keys
        prompt = entry["prompt"] || entry["message"] || entry["input"] || entry["question"]
        return nil if prompt.blank?

        expectations = (entry["expectations"] || entry["expect"] || {}).to_h.stringify_keys
        %w[tools contains not_contains].each do |field|
          expectations[field] = Array(entry[field]) if entry.key?(field)
        end

        scenario(
          prompt: prompt,
          group: entry["group"],
          key: entry["key"],
          notes: entry["notes"],
          expectations: expectations
        )
      end

      def parse_lines(text)
        group = nil
        scenarios = []

        text.each_line do |raw|
          line = raw.strip
          next if line.empty?

          if (heading = heading_for(line))
            group = heading
            next
          end

          scenarios << parse_line(line, group)
        end

        scenarios
      end

      def heading_for(line)
        return Regexp.last_match(1).strip if line =~ HEADING
        return strip_markup(Regexp.last_match(1)) if line =~ BOLD_HEADING
        return line.chomp(":").strip if colon_heading?(line)

        nil
      end

      # `Find records:` reads as a heading; a question, or a line carrying
      # `| options`, does not, however it ends.
      def colon_heading?(line)
        line.end_with?(":") && line.length <= 80 && !line.match?(LIST_MARKER) &&
          !line.include?("?") && !line.include?(" | ")
      end

      def parse_line(line, group)
        body = line.sub(LIST_MARKER, "")
        body, options = split_options(body)

        if (match = body.match(BACKTICK_PROMPT))
          prompt = match[1].strip
          notes = body.sub(match[0], "").sub(/\A\s*[—–-]\s*/, "").strip.presence
        else
          prompt = strip_markup(body)
          notes = nil
        end

        scenario(
          prompt: prompt,
          group: options["group"].presence || group,
          key: options["key"],
          notes: [ notes, options["notes"] ].compact.join(" ").presence,
          expectations: options.slice("tools", "contains", "not_contains").transform_values { |value| split_list(value) }
        )
      end

      # `prompt | tools: a, b | contains: x` → [prompt, { "tools" => "a, b", ... }]
      def split_options(body)
        segments = body.split(/\s+\|\s+/)
        return [ body, {} ] if segments.size == 1

        options = {}
        rest = [ segments.shift ]
        segments.each do |segment|
          key, value = segment.split(":", 2)
          if value && OPTION_KEYS.include?(key.strip.downcase)
            options[key.strip.downcase] = value.strip
          else
            rest << segment
          end
        end

        [ rest.join(" | "), options ]
      end

      def split_list(value)
        value.to_s.split(/\s*[,;]\s*/).map(&:strip).reject(&:blank?)
      end

      def strip_markup(text)
        text.to_s.gsub(/\*\*|__|`/, "").strip
      end

      def scenario(prompt:, group: nil, key: nil, notes: nil, expectations: {})
        {
          "prompt" => prompt.to_s.strip,
          "group" => group.presence&.to_s&.strip,
          "key" => key.presence&.to_s&.strip,
          "notes" => notes.presence,
          "expectations" => (expectations || {}).reject { |_, value| value.blank? }
        }
      end

      # A key named on a line is kept; a generated one never collides with a
      # named key anywhere in the paste; and a named key that repeats an
      # earlier line's is treated as missing, so no two scenarios share one.
      def assign_keys(scenarios)
        named = scenarios.filter_map { |s| s["key"].presence }.to_set
        taken = Set.new
        counters = Hash.new(0)

        scenarios.each_with_index do |scenario, index|
          scenario["position"] = index
          key = scenario["key"].presence
          key = nil if key && taken.include?(key)

          unless key
            base = scenario["group"].to_s.parameterize(separator: "_").first(30).presence || "scenario"
            loop do
              counters[base] += 1
              key = "#{base}_#{counters[base]}"
              break unless named.include?(key) || taken.include?(key)
            end
          end

          taken << key
          scenario["key"] = key
        end

        scenarios
      end
    end
  end
end
