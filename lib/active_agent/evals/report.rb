# frozen_string_literal: true

module ActiveAgent
  module Evals
    # The outcome of one evaluation run: every scenario × model Result, a summary
    # per model, criterion statistics, the faults grouped with the fix each
    # calls for, and the model that did best. Renders as a hash, JSON,
    # Markdown, or a self-contained HTML page (ReportHtml).
    class Report
      include ReportHtml

      # The judge a verdict names when the framework ranked the models by
      # pass rate itself, no judge having been available to rule on them.
      PASS_RATE_JUDGE = "pass rate"

      attr_reader :results, :models, :judge, :judge_label, :instructions, :metadata, :agent_name, :links, :tool_resolver

      # @param tool_resolver [#call, nil] maps a tool name to the MCP server
      #   that provides it — `{ "key", "name", "status" }` with status
      #   "enabled", "available" or "unknown" — or nil; enriches +fix_items+
      # @param agent_name [String, nil] how fix items name the agent
      # @param links [Hash] route templates for fix item actions:
      #   `"mcp"` (`"/mcp/%{key}"`), `"tools"`, `"instructions"`. An action
      #   whose route is absent carries `"path" => nil`.
      # @param verdict [Hash, nil] a verdict already recorded for these
      #   results — `{ "winner", "rationale", "judge" }`. A report rebuilt
      #   from a persisted run renders the pick that run recorded instead of
      #   ranking the results again (and re-asking the judge), so the page
      #   and the dashboard never name two different best models.
      # @param judge_label [String, nil] how to name the judge when no Judge
      #   instance is at hand — a rebuilt run knows only its label.
      # @param judge_usage [Hash, nil] what the judge spent on calls no result
      #   owns — the verdict, authoring criteria — as `{ "calls",
      #   "input_tokens", "output_tokens", "cost", "model", "by_kind",
      #   "source" }`. Each result's own judge calls travel in its replay
      #   metadata (Result#judge_usage); #judge_usage sums the two.
      # @param release [Hash, nil] the release of the agent under evaluation,
      #   `{ "digest", "revision", "label" }`, so the report names the code
      #   it scored: in `to_h["release"]` and as a header chip.
      def initialize(results:, models:, judge: nil, instructions: nil, threshold: PASS_THRESHOLD, metadata: {},
                     tool_resolver: nil, agent_name: nil, links: {}, verdict: nil, judge_label: nil,
                     judge_usage: nil, release: nil)
        @results = results
        @models = models
        @judge = judge
        @judge_label = judge_label.presence
        @instructions = instructions
        @threshold = threshold
        @metadata = metadata
        @tool_resolver = tool_resolver
        @agent_name = agent_name.presence || "the agent"
        @links = (links || {}).to_h.stringify_keys
        @recorded_verdict = verdict.is_a?(Hash) ? verdict.to_h.stringify_keys.presence : nil
        @run_judge_usage = judge_usage.is_a?(Hash) ? judge_usage.to_h.stringify_keys.presence : nil
        @release = release.is_a?(Hash) ? release.to_h.stringify_keys.compact.presence : nil
      end

      # The release of the agent this report scored, `{ "digest",
      # "revision", "label" }`, when the caller named it.
      attr_reader :release

      def comparing?
        @models.size > 1
      end

      # Per model, keyed by label: scenario count, passes, errors, pass rate,
      # mean score, mean latency, tokens, cost and fault counts. "cost" sums
      # the replays that carried a cost — "priced" of the "scenarios", of
      # which "reported" came from the caller and "estimated" from tokens ×
      # a model rate (Result#cost_source) — and is nil when none did.
      # "judge_cost" and "judge_calls" sum what the judge spent on the
      # cohort's results (Result#judge_usage); the judge's cost never joins
      # the agent's.
      def summary_by_model
        @summary_by_model ||= @models.to_h do |spec|
          cohort = @results.select { |result| result.label == spec.label }
          scored = cohort.filter_map(&:score)
          task_scores = cohort.filter_map { |result| result.scores["task_completion"] }
          durations = cohort.filter_map { |result| result.replay.duration_ms }
          costs = cohort.filter_map { |result| result.replay.cost }
          judge_costs = cohort.filter_map { |result| result.judge_usage&.dig("cost") }

          [ spec.label, {
            "provider" => spec.provider,
            "model" => spec.model,
            "scenarios" => cohort.size,
            "passed" => cohort.count(&:passed?),
            "errored" => cohort.count(&:errored?),
            "pass_rate" => cohort.any? ? (cohort.count(&:passed?) * 100.0 / cohort.size).round(1) : 0.0,
            "avg_score" => scored.any? ? (scored.sum / scored.size).round(3) : nil,
            "avg_task_completion" => task_scores.any? ? (task_scores.sum / task_scores.size).round(3) : nil,
            "avg_duration_ms" => durations.any? ? (durations.sum.to_f / durations.size).round : nil,
            "input_tokens" => cohort.sum { |result| result.replay.input_tokens.to_i },
            "output_tokens" => cohort.sum { |result| result.replay.output_tokens.to_i },
            "cost" => costs.any? ? costs.sum.to_f.round(6) : nil,
            "priced" => costs.size,
            "reported" => cohort.count { |result| result.cost_source == "reported" },
            "estimated" => cohort.count(&:estimated_cost?),
            "judge_cost" => judge_costs.any? ? judge_costs.sum.to_f.round(6) : nil,
            "judge_calls" => cohort.sum { |result| result.judge_usage&.dig("calls").to_i },
            "faults" => cohort.filter_map(&:fault).tally
          } ]
        end
      end

      # Per scenario key, in run order: what every model's answer cost
      # together — the agent's cost summed over the models, the judge's, and
      # the two as "total" — plus the same per model under "models", keyed
      # by label, with each result's "cost_source". "estimated" is true when
      # any part was estimated or any model went unpriced (the sum is then a
      # lower bound), which is what a "~" on the figure means. Derived from
      # the results for a matrix column and a cell line; not part of #to_h.
      def scenario_costs
        @scenario_costs ||= @results.group_by { |result| result.scenario.key }.to_h do |key, cohort|
          costs = cohort.filter_map { |result| result.replay.cost }
          judge_costs = cohort.filter_map { |result| result.judge_usage&.dig("cost") }
          cost = costs.any? ? costs.sum.to_f.round(6) : nil
          judge_cost = judge_costs.any? ? judge_costs.sum.to_f.round(6) : nil
          [ key, {
            "cost" => cost,
            "judge_cost" => judge_cost,
            "total" => cost.nil? && judge_cost.nil? ? nil : (cost.to_f + judge_cost.to_f).round(6),
            "estimated" => cohort.any? { |result| result.estimated_cost? || (result.replay.cost.nil? && costs.any?) } ||
                           cohort.any? { |result| estimated_usage?(result.judge_usage) },
            "models" => cohort.to_h do |result|
              [ result.label, { "cost" => result.replay.cost&.to_f, "judge_cost" => result.judge_usage&.dig("cost")&.to_f,
                                "cost_source" => result.cost_source } ]
            end
          } ]
        end
      end

      # What the judge spent on the whole run: every result's own calls
      # (Result#judge_usage) plus the run-level calls handed to `judge_usage:`
      # — `{ "calls", "input_tokens", "output_tokens", "cost", "model",
      # "by_kind", "estimated", "run" => { "calls", "cost", "by_kind" } }`,
      # where "run" is that run-level part alone and "estimated" says a cost
      # in the sum was worked out from tokens rather than reported. nil when
      # no judge was asked anything.
      def judge_usage
        return @judge_usage if defined?(@judge_usage)

        parts = @results.filter_map(&:judge_usage)
        parts << @run_judge_usage if @run_judge_usage
        return @judge_usage = nil if parts.empty?

        costs = parts.filter_map { |usage| usage["cost"] }
        @judge_usage = {
          "calls" => parts.sum { |usage| usage["calls"].to_i },
          "input_tokens" => parts.sum { |usage| usage["input_tokens"].to_i },
          "output_tokens" => parts.sum { |usage| usage["output_tokens"].to_i },
          "cost" => costs.any? ? costs.sum.to_f.round(6) : nil,
          "model" => parts.filter_map { |usage| usage["model"].presence }.first,
          "by_kind" => usage_by_kind(parts),
          "estimated" => parts.any? { |usage| estimated_usage?(usage) },
          "run" => @run_judge_usage && {
            "calls" => @run_judge_usage["calls"].to_i,
            "cost" => @run_judge_usage["cost"]&.to_f,
            "by_kind" => usage_by_kind([ @run_judge_usage ])
          }
        }.compact
      end

      # The run's spend: the agent's cost over every result (nil when none
      # was priced), the judge's (nil without a judge), their "total", and
      # whether any of it is an estimate — the "~" of the cost tile and the
      # footer. "priced" and "unpriced" count the results either way.
      def run_costs
        @run_costs ||= begin
          costs = @results.filter_map { |result| result.replay.cost }
          agent = costs.any? ? costs.sum.to_f.round(6) : nil
          judge = judge_usage&.dig("cost")
          {
            "cost" => agent,
            "judge_cost" => judge,
            "total" => agent.nil? && judge.nil? ? nil : (agent.to_f + judge.to_f).round(6),
            "estimated" => @results.any?(&:estimated_cost?) || (costs.any? && costs.size < @results.size) ||
                           judge_usage&.dig("estimated") == true,
            "priced" => costs.size,
            "unpriced" => @results.size - costs.size
          }
        end
      end

      # Per criterion key: `{ "score", "min", "max", "passed", "total" }` over
      # every result, or a map of model label => those stats when comparing
      # models. A criterion nothing could score is `{ "skipped" => true }`.
      def criterion_scores
        @criterion_scores ||= criterion_keys.to_h do |key|
          stats =
            if comparing?
              @models.to_h do |spec|
                [ spec.label, stats_for(@results.select { |result| result.label == spec.label }.map { |result| result.scores[key] }) ]
              end
            else
              stats_for(@results.map { |result| result.scores[key] })
            end
          [ key, stats ]
        end
      end

      # Faults across scenarios and models, most frequent first, each with the
      # scenarios it hit and the fix it calls for.
      def recommendations
        @recommendations ||= @results.select(&:fault).group_by(&:fault).map do |fault, faulted|
          {
            "fault" => fault,
            "count" => faulted.size,
            "scenario_keys" => faulted.map { |result| result.scenario.key }.uniq,
            "models" => faulted.map(&:label).uniq,
            "recommendation" => faulted.filter_map(&:recommendation).tally.max_by(&:last)&.first,
            "suggested_tools" => faulted.filter_map(&:suggested_tool).uniq
          }
        end.sort_by { |entry| -entry["count"] }
      end

      # What to fix: one item per fault, in +recommendations+ order, plus one
      # per distinct instruction change the judge proposed. Each item names
      # the tools involved — the missing tools a scenario expected, the tools
      # that errored, or the tools the judge suggested — the MCP server that
      # provides them when +tool_resolver+ knows it, and the dashboard action
      # that addresses it when +links+ carry the route:
      #
      #   { "kind" => "fault" | "instruction", "fault" => "expected_tool_not_called", "count" => 3,
      #     "scenario_keys" => [...], "models" => [...], "recommendation" => "...", "quote" => nil,
      #     "tools_label" => "missing tools", "tools" => [ { "name", "note", "server" } ],
      #     "server" => { "key", "name", "status" } | nil, "note" => "..." | nil,
      #     "action" => { "label", "hint", "path" } | nil }
      def fix_items
        @fix_items ||= fault_fix_items + instruction_fix_items
      end

      # The best model when comparing: the verdict the run recorded when one
      # was handed in, else highest pass rate, then mean score, then lowest
      # cost per priced scenario (a model with no cost estimate ranks after
      # one with), with the judge's rationale when one is available. The
      # judge's own spend is no part of the ranking: it measures the
      # evaluation, not the model. `{ "winner", "rationale", "judge" }`, or
      # nil for a single model.
      def verdict
        return @recorded_verdict if @recorded_verdict
        return nil unless comparing?

        @verdict ||= begin
          ranked = summary_by_model.sort_by do |_label, stats|
            [ -stats["pass_rate"].to_f, -stats["avg_score"].to_f, cost_per_priced(stats) || Float::INFINITY ]
          end
          winner, stats = ranked.first
          if stats["cost"]
            cost = " at #{Format.money(stats['cost'], estimated: estimated_cost?(stats))}"
            cost += " (estimated)" if estimated_cost?(stats)
          end
          rationale = "Passed #{stats['passed']} of #{stats['scenarios']} scenarios" \
            " (#{Format.percent(stats['scenarios'].to_i.positive? ? stats['passed'].to_f / stats['scenarios'] : nil)})" \
            "#{" with a mean score of #{Format.score(stats['avg_score'])}" if stats['avg_score']}#{cost}."
          judged = @judge&.verdict(summary_by_model, instructions: @instructions)

          {
            "winner" => judged&.dig("winner").presence || winner,
            "rationale" => judged&.dig("rationale").presence || rationale,
            "judge" => judged ? @judge.label : PASS_RATE_JUDGE
          }
        end
      end

      def winner
        verdict&.dig("winner")
      end

      # Adds "judge_usage" and "release" only when there is one to add, so
      # a report built the way it always was serializes exactly as before.
      def to_h
        {
          "models" => summary_by_model,
          "criteria" => criterion_scores,
          "recommendations" => recommendations,
          "verdict" => verdict,
          "judge" => @judge_label || @judge&.label,
          "judge_usage" => judge_usage,
          "release" => release,
          "metadata" => @metadata.presence,
          "results" => @results.map(&:to_h)
        }.compact
      end

      def to_json(*args)
        JSON.pretty_generate(to_h, *args)
      end

      def to_markdown
        scenario_count = @results.map { |result| result.scenario.key }.uniq.size
        lines = [ "# Evaluation — #{scenario_count} scenario#{'s' unless scenario_count == 1} × #{@models.size} model#{'s' unless @models.size == 1}", "" ]
        label = @judge_label || @judge&.label
        lines << (label ? "Judged by `#{label}`." : "No judge; scored on rules and expectations alone.")
        lines << ""
        lines.concat(summary_table)
        lines << ""
        lines.concat(total_lines)
        lines << "**Best model: #{winner}**" if winner
        lines << ""
        lines.concat(matrix_table)
        lines.concat(detail_lines)
        lines.concat(recommendation_lines)
        lines.join("\n")
      end

      private

      # Whether a model summary's cost is an estimate — any replay priced
      # from tokens, or some replay unpriced, which leaves the sum a lower
      # bound — and so reads with a "~".
      def estimated_cost?(stats)
        stats["estimated"].to_i.positive? || (stats["cost"] && stats["priced"].to_i < stats["scenarios"].to_i)
      end

      # A judge usage whose cost was worked out rather than reported: metered
      # or priced from traces by the caller. One with no source is the
      # caller's own figure.
      def estimated_usage?(usage)
        return false unless usage.is_a?(Hash)

        source = (usage["source"] || usage[:source]).to_s
        source.present? && source != "reported"
      end

      def usage_by_kind(parts)
        parts.each_with_object({}) do |usage, tally|
          (usage["by_kind"] || {}).each { |kind, count| tally[kind.to_s] = tally.fetch(kind.to_s, 0) + count.to_i }
        end
      end

      # A model's cost per priced replay, nil when none was priced.
      def cost_per_priced(stats)
        priced = stats["priced"].to_i
        stats["cost"].to_f / priced if stats["cost"] && priced.positive?
      end

      def criterion_keys
        @results.flat_map { |result| result.scores.keys }.uniq
      end

      def stats_for(values)
        scored = values.compact
        return { "skipped" => true, "reason" => "No scorable answers" } if scored.empty?

        {
          "score" => (scored.sum / scored.size).round(3),
          "min" => scored.min.round(3),
          "max" => scored.max.round(3),
          "passed" => scored.count { |value| value >= @threshold },
          "total" => scored.size
        }
      end

      # --- fix items ---------------------------------------------------------

      def fault_fix_items
        by_fault = @results.select(&:fault).group_by(&:fault)
        recommendations.map do |entry|
          faulted = by_fault[entry["fault"]]
          tools_label, tools = fix_tools(entry["fault"], faulted)
          server = tools_label == "missing tools" ? shared_server(tools) : nil

          {
            "kind" => "fault",
            "fault" => entry["fault"],
            "count" => entry["count"],
            "scenario_keys" => entry["scenario_keys"],
            "models" => entry["models"],
            "recommendation" => fix_recommendation(entry, faulted, tools),
            "quote" => nil,
            "tools_label" => tools.any? ? tools_label : nil,
            "tools" => tools,
            "server" => server,
            "note" => fix_note(entry["fault"], faulted, tools),
            "action" => fix_action(tools_label, tools, server)
          }
        end
      end

      def instruction_fix_items
        @results.select { |result| result.diagnosis&.dig("judge", "instruction_change").present? }
                .group_by { |result| result.diagnosis.dig("judge", "instruction_change").to_s.strip }
                .map do |sentence, cohort|
          {
            "kind" => "instruction",
            "fault" => "instruction change",
            "count" => cohort.size,
            "scenario_keys" => cohort.map { |result| result.scenario.key }.uniq,
            "models" => cohort.map(&:label).uniq,
            # The judge writes one recommendation per result and Runner#refine!
            # puts it on the diagnosis, so it is already the text of the fault
            # card built from the same result: the quote is what this card adds.
            "recommendation" => nil,
            "quote" => sentence,
            "tools_label" => nil,
            "tools" => [],
            "server" => nil,
            "note" => nil,
            "action" => fix_action_for("Add to instructions", "Agent -> Instructions", link("instructions"))
          }
        end
      end

      # The fix the card asks for: the fault's most frequent recommendation,
      # except on an `expected_tool_not_called` card that names missing tools.
      # That card speaks for the scenarios whose tool was unavailable, so its
      # text comes from those alone — the most frequent recommendation may be
      # a scenario whose tool was there all along (a tie is won by whichever
      # was seen first), whose wording contradicts the card's own tools,
      # server and "Enable …" button. That exception keeps its say in +note+.
      def fix_recommendation(entry, faulted, tools)
        return entry["recommendation"] unless entry["fault"] == "expected_tool_not_called" && tools.any?

        blocked = faulted.select { |result| unavailable_tools(result).any? }
        blocked.filter_map(&:recommendation).tally.max_by(&:last)&.first || entry["recommendation"]
      end

      # [label, tools] for a fault: the tools the scenarios expected but the
      # agent could not call, the tools that errored, or the tools the judge
      # suggested — deduplicated by name.
      def fix_tools(fault, faulted)
        case fault
        when "expected_tool_not_called"
          [ "missing tools", faulted.flat_map { |result| unavailable_tools(result) }.uniq.map { |name| tool_entry(name) } ]
        when "missing_capability"
          names = suggested_tool_names(faulted) + faulted.flat_map { |result| unavailable_tools(result) }
          [ "suggested tools", names.uniq.map { |name| tool_entry(name) } ]
        when "tool_error"
          failed = faulted.flat_map { |result| result.replay.failed_tool_calls }.uniq { |call| call["name"].to_s }
          [ "failing tools", failed.map { |call| tool_entry(call["name"], note: call["detail"].to_s.truncate(60).presence) } ]
        else
          [ "suggested tools", suggested_tool_names(faulted).uniq.map { |name| tool_entry(name) } ]
        end
      end

      def suggested_tool_names(faulted)
        faulted.filter_map { |result| result.suggested_tool&.dig("name").presence }
      end

      # Tools the scenario expects that the agent could not call: what the
      # diagnosis recorded as unavailable or, for a diagnosis without that
      # evidence, the expected tools outside its toolset (or, failing that,
      # the ones it did not call).
      def unavailable_tools(result)
        evidence = result.diagnosis&.dig("evidence") || {}
        return Array(evidence["unavailable"]).map(&:to_s) if evidence.key?("unavailable")
        return result.scenario.expected_tools - Array(evidence["tools_available"]).map(&:to_s) if evidence.key?("tools_available")

        result.scenario.expected_tools - result.replay.tool_names
      end

      def tool_entry(name, note: nil)
        server = resolve_tool(name.to_s)
        { "name" => name.to_s, "note" => note || server&.dig("name"), "server" => server }
      end

      def resolve_tool(name)
        return nil unless @tool_resolver

        @resolved_tools ||= {}
        return @resolved_tools[name] if @resolved_tools.key?(name)

        resolved = @tool_resolver.call(name)
        @resolved_tools[name] =
          if resolved
            server = resolved.to_h.stringify_keys
            { "key" => server["key"].to_s, "name" => server["name"].presence || server["key"].to_s,
              "status" => server["status"].presence || "unknown" }
          end
      end

      # The one server every tool resolves to, or nil when they differ or any
      # is unknown.
      def shared_server(tools)
        servers = tools.map { |tool| tool["server"] }
        return nil if servers.empty? || servers.any?(&:nil?)

        servers.uniq { |server| server["key"] }.size == 1 ? servers.first : nil
      end

      # For missing tools, the scenarios whose expected tool was available
      # but went uncalled — the fix for those is instructions, not enabling
      # a server.
      def fix_note(fault, faulted, tools)
        return nil unless fault == "expected_tool_not_called" && tools.any?

        exceptions = faulted.select { |result| unavailable_tools(result).empty? }
        return nil if exceptions.empty?

        exceptions.map { |result| "#{result.scenario.key} is the exception: #{result.summary} #{result.recommendation}".strip }.uniq.join(" ")
      end

      def fix_action(tools_label, tools, server)
        return nil if tools.empty?

        case tools_label
        when "missing tools"
          if server && server["status"] != "enabled"
            fix_action_for("Enable #{server['name']} for #{@agent_name}", "MCP Services ->", link("mcp", key: server["key"]))
          else
            fix_action_for("Open tools", "Tools ->", link("tools"))
          end
        when "failing tools"
          fix_action_for("Open failing tools", "Tools ->", link("tools"))
        else
          fix_action_for("Open suggested tools", "Tools ->", link("tools"))
        end
      end

      def fix_action_for(label, hint, path)
        { "label" => label, "hint" => hint, "path" => path }
      end

      # The route template for `name` with `%{key}`-style values filled in,
      # or nil when the caller gave none.
      def link(name, **values)
        template = @links[name].to_s.presence
        return template if template.nil? || values.empty?

        format(template, **values)
      rescue KeyError, ArgumentError
        template
      end

      # --- Markdown ----------------------------------------------------------

      # The per-model table. A Judge column joins it when a judge spent
      # anything, so the agent's cost and the evaluation's stay two numbers.
      def summary_table
        judged = judge_usage.present?
        columns = [ "Model", "Passed", "Mean score", "Mean latency", "Tokens in/out", "Cost", ("Judge" if judged), "Faults" ].compact
        header = [ "| #{columns.join(' | ')} |", "|#{columns.map { '---' }.join('|')}|" ]
        rows = summary_by_model.map do |label, stats|
          faults = stats["faults"].map { |fault, count| "#{fault.tr('_', ' ')} ×#{count}" }.join(", ")
          latency = stats["avg_duration_ms"] ? "#{stats['avg_duration_ms']} ms" : "—"
          cells = [
            "`#{label}`",
            Format.passes(stats["passed"], stats["scenarios"], style: :markdown),
            Format.score(stats["avg_score"]),
            latency,
            "#{stats['input_tokens']}/#{stats['output_tokens']}",
            Format.money(stats["cost"], estimated: estimated_cost?(stats)),
            (judge_cell(stats) if judged),
            faults.presence || "—"
          ].compact
          "| #{cells.join(' | ')} |"
        end
        header + rows
      end

      # "~$0.0030 (3 calls)" for a model's judge spend, "—" when the judge
      # was not asked about its results.
      def judge_cell(stats)
        return "—" if stats["judge_cost"].nil? && stats["judge_calls"].to_i.zero?

        money = Format.money(stats["judge_cost"], estimated: judge_usage&.dig("estimated") == true)
        "#{money} (#{stats['judge_calls'].to_i} call#{'s' unless stats['judge_calls'].to_i == 1})"
      end

      # "**Total: ~$0.0412** (agent ~$0.0397 · judge ~$0.0015)" under the
      # table, with the legend for "~" when any figure carries it. Nothing
      # for a run with no cost on either side.
      def total_lines
        costs = run_costs
        return [] if costs["total"].nil?

        parts = [ "agent #{Format.money(costs['cost'], estimated: costs['estimated'])}" ]
        parts << "judge #{Format.money(costs['judge_cost'], estimated: judge_usage&.dig('estimated') == true)}" if judge_usage
        lines = [ "**Total: #{Format.money(costs['total'], estimated: costs['estimated'])}** (#{parts.join(' · ')})" ]
        lines << "_#{Format::LEGEND}_" if costs["estimated"]
        lines << ""
      end

      # The scenario matrix, with a trailing Cost column: what the scenario
      # cost across every model, and in brackets what the judge spent on it.
      def matrix_table
        labels = @models.map(&:label)
        header = [ "| Scenario | #{labels.map { |label| "`#{label}`" }.join(' | ')} | Cost |", "|---|#{labels.map { '---' }.join('|')}|---|" ]
        rows = @results.group_by { |result| result.scenario.key }.map do |key, cohort|
          cells = labels.map do |label|
            result = cohort.find { |candidate| candidate.label == label }
            next "—" unless result

            mark = result.passed? ? "✅" : (result.errored? ? "⚠️" : "❌")
            [ mark, (Format.score(result.score) if result.score), result.fault&.tr("_", " ") ].compact.join(" ")
          end
          "| `#{key}` #{cell(cohort.first.scenario.prompt.truncate(70))} | #{cells.join(' | ')} | #{scenario_cost_cell(key)} |"
        end
        header + rows
      end

      # "~$0.0243 (judge ~$0.0015)" for a scenario's total across models.
      def scenario_cost_cell(key)
        costs = scenario_costs[key] || {}
        text = Format.money(costs["cost"], estimated: costs["estimated"])
        text += " (judge #{Format.money(costs['judge_cost'], estimated: costs['estimated'])})" if costs["judge_cost"]
        text
      end

      # A prompt may contain " | " (ScenarioParser keeps it), which would
      # otherwise split the table cell.
      def cell(text)
        text.to_s.gsub("|") { "\\|" }
      end

      def detail_lines
        lines = [ "", "## Answers", "" ]
        @results.each do |result|
          lines << "### `#{result.scenario.key}` · `#{result.label}` · #{result.status}" \
                   "#{" · score #{Format.score(result.score)}" if result.score}#{" · #{answer_cost(result)}" if result.replay.cost}"
          lines << ""
          lines << "> #{result.scenario.prompt}"
          lines << ""
          if result.replay.tool_calls.any?
            lines << "Tools: #{result.replay.tool_calls.map { |call| "#{call['name']}#{' ✗' if call['error']}" }.join(', ')}"
          end
          lines << "Fault: #{result.fault.tr('_', ' ')} — #{result.summary} #{result.recommendation}" if result.fault
          lines << "Error: #{result.replay.error}" if result.replay.error
          lines << ""
          lines << (result.replay.answer.presence || "_(no answer)_").to_s.truncate(1_500)
          lines << ""
        end
        lines
      end

      # "~$0.0243 · judge ~$0.0015": what one answer cost, and what judging
      # it cost.
      def answer_cost(result)
        text = Format.money(result.replay.cost, estimated: result.estimated_cost?)
        judge_cost = result.judge_usage&.dig("cost")
        text += " · judge #{Format.money(judge_cost, estimated: estimated_usage?(result.judge_usage))}" if judge_cost
        text
      end

      # Renders after `detail_lines`, whose trailing blank line separates the two sections.
      def recommendation_lines
        return [] if recommendations.empty?

        lines = [ "## Recommendations", "" ]
        recommendations.each do |entry|
          lines << "- **#{entry['fault'].tr('_', ' ')}** ×#{entry['count']} (#{entry['scenario_keys'].join(', ')}): #{entry['recommendation']}"
          entry["suggested_tools"].each do |tool|
            lines << "  - suggested tool `#{tool['name']}`: #{tool['description']}"
          end
        end
        lines << ""
      end
    end
  end
end
