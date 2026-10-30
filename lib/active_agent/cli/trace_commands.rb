# frozen_string_literal: true

module ActiveAgent
  class CLI
    # `activeagent traces ...`. list and get read through the MCP facade's
    # trace tools; export reads one trace whole as the payload trace ingest
    # takes (traces_export), and import posts such a payload to
    # <mount>/api/traces with the ingest key, so a trace moves between
    # dashboards the way a run report does with `evals report` and `evals
    # import`.
    module TraceCommands
      DURATION = /\A(\d+)([smhd]?)\z/
      DURATION_MINUTES = { "" => 1, "m" => 1, "h" => 60, "d" => 24 * 60 }.freeze

      private

      def traces_list(argv)
        arguments = {}
        argv = parse(argv, "traces list [--agent NAME] [--since 24h] [--status error|ok] [--limit N]") do |p|
          p.on("--agent AGENT", "An agent class name or a dashboard agent's slug") { |v| arguments[:agent] = v }
          p.on("--since DURATION", "How far back: minutes, or 30m, 6h, 7d (default 24h)") { |v| arguments[:since_minutes] = since_minutes(v) }
          p.on("--status STATUS", %w[error ok], "Only failed (error) or successful (ok) traces") { |v| arguments[:status] = v }
          p.on("--service NAME", "Only this reporting service") { |v| arguments[:service] = v }
          p.on("--limit N", "At most N traces (max 100)") { |v| arguments[:limit] = positive_integer(v, "--limit") }
        end
        return EXIT_SUCCESS unless argv
        raise Error.new("unexpected arguments: #{argv.join(" ")}", exit_code: EXIT_USAGE) unless argv.empty?

        payload = client.tool("traces_search", arguments)
        traces = payload.fetch("traces", [])
        emit(payload) do
          table(traces, {
            "TRACE" => ->(t) { t["short_id"] },
            "TIME" => ->(t) { t["timestamp"] },
            "AGENT" => ->(t) { [ t["agent"], t["action"] ].compact.join("#") },
            "MODEL" => ->(t) { t["model"] },
            "STATUS" => ->(t) { t["status"] },
            "MS" => ->(t) { t["duration_ms"] },
            "TOKENS" => ->(t) { t.dig("tokens", "total") }
          }, empty: "No traces in the last #{payload["window_minutes"]} minutes.")
          @out.puts "(more traces match; raise --limit or narrow the filters)" if payload["truncated"]
        end
      end

      # One trace as the dashboard's trace page shows it: its spans, tool
      # calls and errors, with long values cut (traces_get).
      def traces_get(argv)
        argv = parse(argv, "traces get TRACE")
        return EXIT_SUCCESS unless argv

        trace_id = require_argument(argv, "TRACE (a trace id, or its first 8 characters)", "traces get TRACE")
        payload = client.tool("traces_get", trace_id: trace_id)
        emit(payload) do
          @out.puts "Trace #{payload["trace_id"]}: #{[ payload["agent"], payload["action"] ].compact.join("#")} " \
                    "on #{payload["model"] || "-"} (#{payload["status"]}, #{payload["duration_ms"]} ms, " \
                    "#{payload.dig("tokens", "total")} tokens)"
          @out.puts "Error: #{payload["error"]}" if payload["error"]
          table(Array(payload["spans"]), {
            "SPAN" => ->(s) { s["span_id"] },
            "TYPE" => ->(s) { s["type"] },
            "NAME" => ->(s) { s["name"] },
            "START" => ->(s) { s["start"] },
            "MS" => ->(s) { s["duration"] },
            "STATUS" => ->(s) { s["status"] }
          }, empty: "No spans.")
          omitted = payload["spans_omitted"].to_i
          @out.puts "(#{omitted} more spans; `activeagent traces export #{payload["trace_id"]}` has them all)" if omitted.positive?
        end
      end

      # Writes the trace, whole, as the payload POST <mount>/api/traces
      # ingests ({ traces: [trace], sdk }), which `traces import` sends.
      def traces_export(argv)
        output = nil
        argv = parse(argv, "traces export TRACE [-o FILE]") do |p|
          p.on("-o", "--output FILE", "Write to FILE instead of standard output") { |v| output = v }
        end
        return EXIT_SUCCESS unless argv

        trace_id = require_argument(argv, "TRACE (a trace id, or its first 8 characters)", "traces export TRACE")
        payload = client.tool("traces_export", trace_id: trace_id)
        write_output(JSON.pretty_generate(payload), output) do
          "Wrote trace #{payload.dig("traces", 0, "trace_id")} to #{output}."
        end
      end

      # Posts a saved trace payload to the dashboard's trace ingest with the
      # ingest key. FILE is what `traces export` writes, or one trace object,
      # or the batch a reporter would send. A trace_id the dashboard already
      # holds is skipped there, so importing the same file twice stores
      # nothing more.
      def traces_import(argv)
        argv = parse(argv, "traces import FILE")
        return EXIT_SUCCESS unless argv

        path = require_argument(argv, "FILE", "traces import FILE")
        document = read_json_file(path)
        payload = document.key?("traces") ? document : { "traces" => [ document ] }
        traces = payload["traces"]
        unless traces.is_a?(Array) && traces.any? && traces.all? { |trace| trace.is_a?(Hash) && trace["trace_id"].is_a?(String) }
          raise Error.new("#{path} holds no traces: it is the { \"traces\": [...] } payload `traces export` writes, " \
                          "or one trace with a trace_id", exit_code: EXIT_USAGE)
        end
        payload["sdk"] = { "name" => "activeagent-cli", "version" => self.class.version } unless payload["sdk"].is_a?(Hash) && !payload["sdk"].empty?

        client.post("/api/traces", JSON.generate(payload))
        trace_ids = traces.map { |trace| trace["trace_id"] }
        emit(accepted: true, trace_ids: trace_ids, endpoint: client.traces_endpoint) do
          @out.puts "Sent #{trace_ids.size} trace#{"s" unless trace_ids.size == 1} to #{client.traces_endpoint}: #{trace_ids.join(", ")}."
        end
      end

      # Minutes in a duration such as 90, 30m, 6h or 7d; seconds round up
      # to a whole minute.
      def since_minutes(value)
        match = DURATION.match(value.to_s.strip.downcase)
        raise Error.new("--since must be minutes or a duration such as 30m, 6h or 7d", exit_code: EXIT_USAGE) unless match

        amount = match[1].to_i
        minutes = match[2] == "s" ? (amount / 60.0).ceil : amount * DURATION_MINUTES.fetch(match[2])
        raise Error.new("--since must be at least a minute", exit_code: EXIT_USAGE) unless minutes.positive?

        minutes
      end
    end

    include TraceCommands
  end
end
