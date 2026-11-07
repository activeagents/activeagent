# frozen_string_literal: true

require "uri"

module ActiveAgent
  class CLI
    # `activeagent evals ...`. list, runs and run go through the MCP facade's
    # evaluation tools; import posts a version-1 report to the collector with
    # ActiveAgent::Evals::Publisher; report reads one back from the
    # collector's export endpoint.
    module EvalCommands
      # How `evals report` asks GET <mount>/api/evaluation_reports/:run_id
      # for each format. The JSON form is the version-1 envelope the
      # collector takes, so `evals report --format json` then `evals import`
      # copies a run between installs.
      REPORT_FORMATS = {
        "json" => { accept: "application/json", query: nil },
        "html" => { accept: "text/html", query: "format=html" },
        # GitHub-flavored Markdown, for a pull request comment:
        # `activeagent evals report RUN --format md | gh pr comment 12 --body-file -`
        "md" => { accept: "text/markdown", query: "format=md" }
      }.freeze

      RUN_FINISHED = %w[complete failed].freeze
      DEFAULT_WAIT_TIMEOUT = 30 * 60
      DEFAULT_POLL_INTERVAL = 5
      FAILURES_SHOWN = 20

      private

      def evals_list(argv)
        arguments = {}
        argv = parse(argv, "evals list [--agent SLUG] [--limit N]") do |p|
          p.on("--agent AGENT", "Only this agent's evaluations, by slug or id") { |v| arguments[:agent] = v }
          p.on("--limit N", "At most N evaluations (max 50)") { |v| arguments[:limit] = positive_integer(v, "--limit") }
        end
        return EXIT_SUCCESS unless argv

        evaluations = client.tool("evaluations_list", arguments).fetch("evaluations", [])
        emit(evaluations: evaluations) do
          table(evaluations, {
            "ID" => ->(e) { e["id"] },
            "NAME" => ->(e) { e["name"] },
            "AGENT" => ->(e) { e.dig("agent", "slug") },
            "SCENARIOS" => ->(e) { e["scenario_count"] },
            "RUNS" => ->(e) { e["run_count"] },
            "LATEST" => ->(e) { e.dig("latest_run", "status") },
            "PASSED" => ->(e) { passed(e["latest_run"]) }
          }, empty: "No evaluations.")
        end
      end

      def evals_runs(argv)
        argv = parse(argv, "evals runs EVALUATION")
        return EXIT_SUCCESS unless argv

        evaluation_id = resolve_evaluation(require_argument(argv, "EVALUATION (an id or name)", "evals runs EVALUATION"))
        payload = client.tool("evaluations_get", evaluation_id: evaluation_id)
        runs = payload.fetch("runs", [])
        emit(evaluation: payload["evaluation"], runs: runs) do
          @out.puts "#{payload.dig("evaluation", "name")} (evaluation #{evaluation_id})"
          table(runs, {
            "RUN" => ->(r) { r["id"] },
            "#" => ->(r) { r["number"] },
            "STATUS" => ->(r) { r["status"] },
            "PASSED" => ->(r) { passed(r) },
            "SCORE" => ->(r) { r["average_score"] },
            "CREATED" => ->(r) { r["created_at"] },
            # The handle `evals report` takes.
            "RUN_ID" => ->(r) { r["run_id"] }
          }, empty: "No runs yet.")
        end
      end

      # Starts a run. With --wait (implied by --min-pass-rate), polls it to
      # the end and exits EXIT_GATE when it failed or passed fewer scenarios
      # than the threshold, so a CI step fails the build.
      def evals_run(argv)
        arguments = {}
        wait = false
        min_pass_rate = nil
        timeout = DEFAULT_WAIT_TIMEOUT
        interval = DEFAULT_POLL_INTERVAL
        argv = parse(argv, "evals run EVALUATION [--models a,b] [--wait] [--min-pass-rate 0.8]") do |p|
          p.on("--models LIST", "Candidate models to compare, comma-separated") { |v| arguments[:models] = list_option(v) }
          p.on("--keys LIST", "Replay only these scenario keys, comma-separated") { |v| arguments[:keys] = list_option(v) }
          p.on("--group GROUP", "Replay only this scenario group") { |v| arguments[:group] = v }
          p.on("--sandbox ID", "Replay against this ready checkout sandbox") { |v| arguments[:sandbox_id] = v }
          p.on("--wait", "Wait for the run to finish; fail (exit #{EXIT_GATE}) when it failed or missed a pass gate") { wait = true }
          p.on("--min-pass-rate RATE", "Also fail below this whole-run pass rate: 0.8 or 80%; implies --wait") do |v|
            min_pass_rate = pass_rate_option(v)
            wait = true
          end
          p.on("--timeout SECONDS", "Give up waiting after this long (default #{DEFAULT_WAIT_TIMEOUT})") { |v| timeout = positive_integer(v, "--timeout") }
          p.on("--interval SECONDS", "Poll this often (default #{DEFAULT_POLL_INTERVAL})") { |v| interval = positive_integer(v, "--interval") }
        end
        return EXIT_SUCCESS unless argv

        evaluation_id = resolve_evaluation(require_argument(argv, "EVALUATION (an id or name)", "evals run EVALUATION"))
        started = client.tool("evaluations_run", arguments.merge(evaluation_id: evaluation_id))
        run = started.fetch("run", {})
        @err.puts "Started run #{run["id"]} of #{started.dig("evaluation", "name")} (evaluation #{evaluation_id})." unless @options[:json]
        unless wait
          return emit(started) { @out.puts "Status: #{run["status"]}. Follow it with `activeagent evals runs #{evaluation_id}`." }
        end

        finished = wait_for_run(evaluation_id, run["id"], timeout: timeout, interval: interval)
        gate(finished, min_pass_rate)
      end

      # Without --format, a terminal gets Markdown to read and anything else
      # (a pipe, a file, -o) gets the JSON envelope, so scripts see JSON.
      # RUN is the run's run_id: the RUN_ID column of `evals runs`, which is
      # a published run's own run_id and a dashboard run's
      # dashboard-run-<id>-<created_at>.
      def evals_report(argv)
        format = nil
        output = nil
        argv = parse(argv, "evals report RUN [--format json|html|md] [-o FILE]") do |p|
          p.on("--format FORMAT", REPORT_FORMATS.keys,
               "json (a version-1 envelope), html or md; default md on a terminal, json otherwise") { |v| format = v }
          p.on("-o", "--output FILE", "Write to FILE instead of standard output") { |v| output = v }
        end
        return EXIT_SUCCESS unless argv

        run_id = require_argument(argv, "RUN (the run's run_id, the RUN_ID of `evals runs`)", "evals report RUN")
        format ||= !output && @out.respond_to?(:tty?) && @out.tty? ? "md" : "json"
        request = REPORT_FORMATS.fetch(format)
        response = client.get("/api/evaluation_reports/#{URI.encode_www_form_component(run_id).gsub("+", "%20")}",
                              accept: request[:accept], query: request[:query],
                              missing: "No report for run #{run_id}; `activeagent evals runs EVALUATION` shows each run's RUN_ID",
                              unavailable: "This dashboard has no report export (GET <mount>/api/evaluation_reports/:run_id); " \
                                           "it predates actionagent 1.9.3")
        body = response.body.to_s
        body = JSON.pretty_generate(report_envelope(body)) if format == "json"
        write_output(body, output) { "Wrote #{format} report for run #{run_id} to #{output}." }
      end

      # Posts a saved report to the collector. FILE is a version-1 envelope
      # (what `evals report --format json` writes) or a bare Report#to_h
      # hash, whose identities then come from the options; the publisher
      # reads the run_id from the report's metadata when neither names one.
      def evals_import(argv)
        identities = {}
        argv = parse(argv, "evals import FILE [--run-id ID --source NAME --agent NAME --suite NAME]") do |p|
          p.on("--run-id ID", "The report's run_id, kept across retries; by default the one its metadata records") { |v| identities["run_id"] = v }
          p.on("--source NAME", "The application that ran it") { |v| identities["source"] = v }
          p.on("--agent NAME", "The agent's name") { |v| identities["agent_name"] = v }
          p.on("--suite NAME", "The suite's name") { |v| identities["suite"] = v }
        end
        return EXIT_SUCCESS unless argv

        path = require_argument(argv, "FILE", "evals import FILE")
        document = read_json_file(path)
        envelope = document.key?("version") && document.key?("report") ? document : { "report" => document }
        if envelope.key?("version") && envelope["version"] != 1
          raise Error.new("#{path} is a version #{envelope["version"].inspect} envelope; this CLI sends version 1", exit_code: EXIT_USAGE)
        end
        envelope = envelope.merge(identities)

        receipt = client.publisher.call(report: envelope["report"], run_id: envelope["run_id"], source: envelope["source"],
                                        agent_name: envelope["agent_name"], suite: envelope["suite"])
        emit(receipt) do
          @out.puts "#{receipt["duplicate"] ? "Already stored" : "Imported"} run #{receipt["run_id"]} " \
                    "(evaluation #{receipt["evaluation_id"]}, run #{receipt["id"]})."
        end
      rescue ArgumentError => e
        raise Error.new("#{e.message}; give it with --run-id, --source, --agent or --suite", exit_code: EXIT_USAGE)
      rescue ActiveAgent::Evals::Publisher::Error => e
        raise Error.new(e.message, status: e.status)
      end

      # An evaluation's id, from an id or its exact name among the first 50
      # evaluations the key can reach.
      def resolve_evaluation(value)
        return Integer(value, 10) if value.match?(/\A\d+\z/)

        matches = client.tool("evaluations_list", limit: 50).fetch("evaluations", []).select { |e| e["name"] == value }
        case matches.size
        when 1 then matches.first["id"]
        when 0 then raise Error, "No evaluation named #{value.inspect}; `activeagent evals list` shows them"
        else
          raise Error.new("#{matches.size} evaluations are named #{value.inspect} (ids #{matches.map { |e| e["id"] }.join(", ")}); " \
                          "pass the id", exit_code: EXIT_USAGE)
        end
      end

      def wait_for_run(evaluation_id, run_id, timeout:, interval:)
        deadline = @clock.call + timeout
        loop do
          payload = client.tool("evaluation_runs_get", evaluation_id: evaluation_id, run_id: run_id, failed_only: true, limit: FAILURES_SHOWN)
          return payload if RUN_FINISHED.include?(payload.dig("run", "status"))

          if @clock.call >= deadline
            raise Error, "Run #{run_id} is still #{payload.dig("run", "status")} after #{timeout}s; " \
                         "raise --timeout or follow it with `activeagent evals runs #{evaluation_id}`"
          end
          @sleeper.call(interval)
        end
      end

      # A finished run fails the gate when it failed, when its whole pass
      # rate is under --min-pass-rate, or when it was held to per-group pass
      # gates (the run's "gates", from the suite's or catalog set's `pass`
      # bars) and the dashboard says it did not meet every one. A run
      # without gates is gated on its status and rate alone, as it was.
      def gate(payload, min_pass_rate)
        run = payload.fetch("run", {})
        rate = pass_rate(run)
        failed = run["status"] == "failed"
        below = min_pass_rate && (rate.nil? || rate < min_pass_rate)
        gates = run_gates(run)
        missed = !gates.nil? && run["gates_met"] != true
        verdict = failed || below || missed ? "fail" : "pass"
        failures = payload.fetch("results", [])
        summary = { "pass_rate" => rate, "min_pass_rate" => min_pass_rate }
        summary["gates"] = gates if gates

        emit(payload.merge(summary).merge("verdict" => verdict)) do
          @out.puts "Run #{run["id"]} #{run["status"]}: #{passed(run) || "no results"}" \
                    "#{rate ? format(" (%.1f%%)", rate * 100) : ""}#{min_pass_rate ? format(", threshold %.1f%%", min_pass_rate * 100) : ""}."
          @out.puts "Error: #{run["error_message"]}" if run["error_message"]
          print_gates(gates, missed) if gates
          unless failures.empty?
            @out.puts "Failed results:"
            table(failures, {
              "SCENARIO" => ->(r) { r["scenario_key"] },
              "MODEL" => ->(r) { r["model"] },
              "STATUS" => ->(r) { r["status"] },
              "FAULT" => ->(r) { r["fault"] },
              "TRACE" => ->(r) { r["trace_id"] }
            })
          end
          @out.puts "Report: activeagent evals report #{run["run_id"]}" if run["run_id"]
          @out.puts(verdict == "pass" ? "PASS" : "FAIL")
        end
        verdict == "pass" ? EXIT_SUCCESS : EXIT_GATE
      end

      # The run's per-group pass gates as the dashboard worked them out
      # (EvaluationRun#gates), or nil for a run held to none.
      def run_gates(run)
        rows = run["gates"]
        rows.select { |row| row.is_a?(Hash) } if rows.is_a?(Array)
      end

      def print_gates(gates, missed)
        unmet = gates.reject { |gate| gate["met"] == true }
        unless missed
          @out.puts "Gates: every gate met (#{gates.size})."
          return
        end

        @out.puts(unmet.empty? ? "Gates: no gate was reached." : "Gates not met:")
        unmet.each { |gate| @out.puts "  #{gate_sentence(gate)}" }
      end

      # A gate the run missed, as ActiveAgent::Evals::Report::Gate#to_s
      # reads it: "Orders · gpt-5-mini: 1/2 (50%) passed, below 100%".
      def gate_sentence(gate)
        passed = gate["passed"].to_i
        total = gate["total"].to_i
        passes = total.positive? ? "#{passed}/#{total} (#{whole_percent(passed.to_f / total)})" : "no results"
        label = cell(gate["label"]) unless gate["label"].to_s.empty?
        "#{cell(gate["name"] || gate["group"] || "All")}#{label ? " · #{label}" : ""}: #{passes} passed, below #{whole_percent(gate["min_pass_rate"])}"
      end

      def whole_percent(fraction)
        value = Float(fraction, exception: false)
        value ? "#{(value * 100).round}%" : "?"
      end

      def pass_rate(run)
        evaluated = run["samples_evaluated"].to_i
        evaluated.positive? ? run["samples_passed"].to_f / evaluated : nil
      end

      def passed(run)
        return unless run.is_a?(Hash) && run["samples_evaluated"]

        "#{run["samples_passed"].to_i}/#{run["samples_evaluated"]}"
      end

      def pass_rate_option(value)
        rate = value.end_with?("%") ? Float(value.delete_suffix("%")) / 100 : Float(value)
        raise ArgumentError unless rate.between?(0, 1)

        rate
      rescue ArgumentError, TypeError
        raise Error.new("--min-pass-rate must be a rate between 0 and 1, or a percentage such as 80%", exit_code: EXIT_USAGE)
      end

      # The collector's export must be the envelope `evals import` sends back.
      def report_envelope(body)
        envelope = JSON.parse(body)
        unless envelope.is_a?(Hash) && envelope["version"] == 1 && envelope["report"].is_a?(Hash)
          raise Error, "The dashboard's report is not a version-1 envelope"
        end
        envelope
      rescue JSON::ParserError
        raise Error.new("The dashboard returned invalid JSON for the report"), cause: nil
      end
    end

    include EvalCommands
  end
end
