# frozen_string_literal: true

module ActiveAgent
  module Evals
    # The outcome of one evaluation run: every scenario × model Result, a summary
    # per model, criterion statistics, the faults grouped with the fix each
    # calls for, and the model that did best. Renders as a hash, JSON,
    # Markdown, or a self-contained HTML page (ReportHtml).
    class Report
      include ReportHtml

      attr_reader :results, :models, :judge, :instructions, :metadata, :agent_name, :links, :tool_resolver

      # @param tool_resolver [#call, nil] maps a tool name to the MCP server
      #   that provides it — `{ "key", "name", "status" }` with status
      #   "enabled", "available" or "unknown" — or nil; enriches +fix_items+
      # @param agent_name [String, nil] how fix items name the agent
      # @param links [Hash] route templates for fix item actions:
      #   `"mcp"` (`"/mcp/%{key}"`), `"tools"`, `"instructions"`. An action
      #   whose route is absent carries `"path" => nil`.
      def initialize(results:, models:, judge: nil, instructions: nil, threshold: PASS_THRESHOLD, metadata: {},
                     tool_resolver: nil, agent_name: nil, links: {})
        @results = results
        @models = models
        @judge = judge
        @instructions = instructions
        @threshold = threshold
        @metadata = metadata
        @tool_resolver = tool_resolver
        @agent_name = agent_name.presence || "the agent"
        @links = (links || {}).to_h.stringify_keys
      end

      def comparing?
        @models.size > 1
      end

      # Per model, keyed by label: scenario count, passes, errors, pass rate,
      # mean score, mean latency, tokens, cost and fault counts.
      def summary_by_model
        @summary_by_model ||= @models.to_h do |spec|
          cohort = @results.select { |result| result.label == spec.label }
          scored = cohort.filter_map(&:score)
          durations = cohort.filter_map { |result| result.replay.duration_ms }
          costs = cohort.filter_map { |result| result.replay.cost }

          [ spec.label, {
            "provider" => spec.provider,
            "model" => spec.model,
            "scenarios" => cohort.size,
            "passed" => cohort.count(&:passed?),
            "errored" => cohort.count(&:errored?),
            "pass_rate" => cohort.any? ? (cohort.count(&:passed?) * 100.0 / cohort.size).round(1) : 0.0,
            "avg_score" => scored.any? ? (scored.sum / scored.size).round(3) : nil,
            "avg_duration_ms" => durations.any? ? (durations.sum.to_f / durations.size).round : nil,
            "input_tokens" => cohort.sum { |result| result.replay.input_tokens.to_i },
            "output_tokens" => cohort.sum { |result| result.replay.output_tokens.to_i },
            "cost" => costs.any? ? costs.sum.to_f.round(6) : nil,
            "faults" => cohort.filter_map(&:fault).tally
          } ]
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

      # The best model when comparing: highest pass rate, then mean score, then
      # lowest cost (a model with no cost estimate ranks after one with),
      # with the judge's rationale when one is available.
      # `{ "winner", "rationale", "judge" }`, or nil for a single model.
      def verdict
        return nil unless comparing?

        @verdict ||= begin
          ranked = summary_by_model.sort_by do |_label, stats|
            [ -stats["pass_rate"].to_f, -stats["avg_score"].to_f, stats["cost"] || Float::INFINITY ]
          end
          winner, stats = ranked.first
          rationale = "Passed #{stats['passed']} of #{stats['scenarios']} scenarios" \
            "#{" with a mean score of #{stats['avg_score']}" if stats['avg_score']}" \
            "#{" at an estimated $#{format('%.4f', stats['cost'])}" if stats['cost']}."
          judged = @judge&.verdict(summary_by_model, instructions: @instructions)

          {
            "winner" => judged&.dig("winner").presence || winner,
            "rationale" => judged&.dig("rationale").presence || rationale,
            "judge" => judged ? @judge.label : "pass rate"
          }
        end
      end

      def winner
        verdict&.dig("winner")
      end

      def to_h
        {
          "models" => summary_by_model,
          "criteria" => criterion_scores,
          "recommendations" => recommendations,
          "verdict" => verdict,
          "judge" => @judge&.label,
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
        lines << (@judge ? "Judged by `#{@judge.label}`." : "No judge; scored on rules and expectations alone.")
        lines << ""
        lines.concat(summary_table)
        lines << ""
        lines << "**Best model: #{winner}**" if winner
        lines << ""
        lines.concat(matrix_table)
        lines.concat(recommendation_lines)
        lines.concat(detail_lines)
        lines.join("\n")
      end

      private

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
            "recommendation" => entry["recommendation"],
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
            "recommendation" => cohort.filter_map(&:recommendation).first,
            "quote" => sentence,
            "tools_label" => nil,
            "tools" => [],
            "server" => nil,
            "note" => nil,
            "action" => fix_action_for("Add to instructions", "Agent -> Instructions", link("instructions"))
          }
        end
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

      def summary_table
        header = [ "| Model | Pass rate | Passed | Mean score | Mean latency | Tokens in/out | Cost | Faults |",
                   "|---|---|---|---|---|---|---|---|" ]
        rows = summary_by_model.map do |label, stats|
          faults = stats["faults"].map { |fault, count| "#{fault.tr('_', ' ')} ×#{count}" }.join(", ")
          latency = stats["avg_duration_ms"] ? "#{stats['avg_duration_ms']} ms" : "—"
          cost = stats["cost"] ? format("$%.4f", stats["cost"]) : "—"
          "| `#{label}` | #{stats['pass_rate']}% | #{stats['passed']}/#{stats['scenarios']} | #{stats['avg_score'] || '—'} | " \
            "#{latency} | #{stats['input_tokens']}/#{stats['output_tokens']} | #{cost} | #{faults.presence || '—'} |"
        end
        header + rows
      end

      def matrix_table
        labels = @models.map(&:label)
        header = [ "| Scenario | #{labels.map { |label| "`#{label}`" }.join(' | ')} |", "|---|#{labels.map { '---' }.join('|')}|" ]
        rows = @results.group_by { |result| result.scenario.key }.map do |key, cohort|
          cells = labels.map do |label|
            result = cohort.find { |candidate| candidate.label == label }
            next "—" unless result

            mark = result.passed? ? "✅" : (result.errored? ? "⚠️" : "❌")
            [ mark, result.score&.round(2), result.fault&.tr("_", " ") ].compact.join(" ")
          end
          "| `#{key}` #{cell(cohort.first.scenario.prompt.truncate(70))} | #{cells.join(' | ')} |"
        end
        header + rows
      end

      # A prompt may contain " | " (ScenarioParser keeps it), which would
      # otherwise split the table cell.
      def cell(text)
        text.to_s.gsub("|") { "\\|" }
      end

      def recommendation_lines
        return [] if recommendations.empty?

        lines = [ "", "## Recommendations", "" ]
        recommendations.each do |entry|
          lines << "- **#{entry['fault'].tr('_', ' ')}** ×#{entry['count']} (#{entry['scenario_keys'].join(', ')}): #{entry['recommendation']}"
          entry["suggested_tools"].each do |tool|
            lines << "  - suggested tool `#{tool['name']}`: #{tool['description']}"
          end
        end
        lines
      end

      def detail_lines
        lines = [ "", "## Answers", "" ]
        @results.each do |result|
          lines << "### `#{result.scenario.key}` · `#{result.label}` · #{result.status}#{" · score #{result.score.round(2)}" if result.score}"
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
    end
  end
end
