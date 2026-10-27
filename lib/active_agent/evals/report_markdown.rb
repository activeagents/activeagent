# frozen_string_literal: true

module ActiveAgent
  module Evals
    # Report#to_markdown: the run as GitHub-flavored Markdown with the same
    # content as Report#to_html — the per-model table and the cost, the
    # verdict with the model comparison, the scenario matrix, every answer
    # (one `<details>` block per scenario, since GitHub strips the HTML
    # page's styles), and What to fix from Report#fix_items — so it can be
    # pasted into a pull request or an issue.
    #
    # Each piece is public on its own, for the pieces people paste one at a
    # time: #fix_item_markdown, #fix_items_markdown (optionally for one
    # model), #verdict_markdown and #scenario_markdown. The whole report is
    # built from them, so a piece copied alone reads as it does in the report.
    #
    # Table cells escape `|` and fold line breaks; text set inside the HTML
    # of a `<details>` block escapes `<`, `>` and `&`.
    module ReportMarkdown
      # How much of an answer the whole report quotes; a scenario copied on
      # its own quotes the whole answer.
      MARKDOWN_ANSWER_LIMIT = 1_500

      def to_markdown
        lines = [ "# #{markdown_title}", "" ]
        lines << judged_by_line
        lines << ""
        lines.concat(summary_table)
        lines << ""
        lines.concat(total_lines)
        lines.concat(verdict_lines)
        lines.concat(comparison_lines)
        lines.concat(matrix_table)
        lines.concat([ "", "## Answers", "" ])
        scenario_keys.each { |key| lines << scenario_markdown(key, details: true, answer_limit: MARKDOWN_ANSWER_LIMIT) << "" }
        lines << fix_items_markdown(heading: "##")
        "#{lines.join("\n").rstrip}\n"
      end

      # One fix item (Report#fix_items) as a heading and its body: the fault
      # and how often, the scenarios and models it covers, the
      # recommendation, the judge's proposed instruction change as a quote,
      # the tools involved, the server that serves them, the note and where
      # in the dashboard the fix lives.
      def fix_item_markdown(item, heading: "###")
        item = item.to_h.stringify_keys
        title = item["fault"].to_s.tr("_", " ") + (item["count"].to_i > 1 ? " ×#{item['count']}" : "")
        lines = [ "#{heading} #{item['kind'] == 'instruction' ? 'ℹ️' : '❗'} #{title}", "" ]

        scope = [ "Scenarios: #{Array(item['scenario_keys']).map { |key| "`#{key}`" }.join(', ')}" ]
        scope << "models: #{Array(item['models']).map { |label| "`#{label}`" }.join(', ')}" if Array(item["models"]).any?
        scope << "judge suggestion" if item["kind"] == "instruction"
        lines << scope.join(" · ") << ""
        lines << item["recommendation"].to_s.strip << "" if item["recommendation"].present?
        lines.concat(quoted(item["quote"]).push("")) if item["quote"].present?
        tools = Array(item["tools"])
        if tools.any?
          lines << "**#{item['tools_label'].presence || 'tools'}:** " + tools.map { |tool| tool_text(tool) }.join(", ")
          lines << ""
        end
        if (server = item["server"])
          state = server["status"] == "enabled" ? "enabled for #{@agent_name}" : "#{server['status'].presence || 'unknown'} · not enabled for #{@agent_name}"
          lines << "Served by **#{server['name'].presence || server['key']}** (#{state})" << ""
        end
        lines << "_#{item['note'].to_s.strip}_" << "" if item["note"].present?
        if (action = item["action"])
          lines << "Fix: #{[ action['label'], action['hint'] ].compact_blank.join(' — ')}" << ""
        end
        lines.join("\n").rstrip
      end

      # What to fix: every fix item, or with +model+ (a model label) the ones
      # attributed to that model, as the report's model filter shows them.
      def fix_items_markdown(model: nil, heading: "##")
        items = fix_items
        items = items.select { |item| Array(item["models"]).empty? || item["models"].include?(model) } if model.present?
        lines = [ "#{heading} What to fix#{" for `#{model}`" if model.present?}", "" ]
        if items.empty?
          lines << "_Nothing to fix._"
        else
          sub = "#{heading}#"
          lines << items.map { |item| fix_item_markdown(item, heading: sub) }.join("\n\n")
        end
        lines.join("\n")
      end

      # The verdict — the best model, why, and who picked it — then the
      # per-model table and, comparing models, the comparison with its
      # intervals.
      def verdict_markdown(heading: "##")
        lines = [ "#{heading} Verdict", "", judged_by_line, "" ]
        lines.concat(verdict_lines)
        lines.concat(summary_table)
        lines << ""
        lines.concat(total_lines)
        lines.concat(comparison_lines.map { |line| line.start_with?("## ") ? line.sub("## ", "#{heading}# ") : line })
        lines.join("\n").rstrip
      end

      # One scenario: its prompt and expectations, a table of each model's
      # status, score, tool calls, fault and cost, then each model's answer.
      # With +details+ it is a `<details>` block whose summary names the key,
      # the prompt and each model's mark, the way the report folds it.
      # Raises KeyError for a key the report has no result for.
      def scenario_markdown(key, details: false, answer_limit: nil)
        cohort = @results.select { |result| result.scenario.key == key.to_s }
        raise KeyError, "no results for scenario #{key}" if cohort.empty?

        scenario = cohort.first.scenario
        labels = @models.map(&:label)
        cohort = cohort.sort_by { |result| labels.index(result.label) || labels.size }
        body = []
        body << "**Prompt**" << "" << quoted(scenario.prompt).join("\n") << ""
        expectations = expectation_lines(scenario)
        body.concat(expectations).push("") if expectations.any?
        body << "| Model | Status | Score | Tools | Fault | Cost |" << "|---|---|---|---|---|---|"
        cohort.each do |result|
          tools = result.replay.tool_calls.map { |call| "#{call['name']}#{' ✗' if call['error']}" }.join(", ")
          body << "| #{[ "`#{result.label}`", status_text(result), (result.score ? Format.score(result.score) : '—'), tools.presence || '—',
                         result.fault&.tr('_', ' ') || '—', (result.replay.cost ? answer_cost(result) : '—') ].map { |text| cell(text) }.join(' | ')} |"
        end
        body << ""
        cohort.each do |result|
          body << "**`#{result.label}`** — #{status_text(result)}"
          body << ""
          body << "Fault: #{result.fault.tr('_', ' ')} — #{[ result.summary, result.recommendation ].compact.join(' ')}" << "" if result.fault
          body << "Error: #{result.replay.error}" << "" if result.replay.error
          answer = result.replay.answer.to_s
          answer = answer.truncate(answer_limit) if answer_limit
          body << (answer.present? ? quoted(answer).join("\n") : "_(no answer)_") << ""
        end
        text = body.join("\n").rstrip
        return "### Scenario `#{scenario.key}`\n\n#{text}" unless details

        marks = cohort.map { |result| "#{status_mark(result)} #{result.label}" }.join(" · ")
        summary = "<code>#{html_text(scenario.key)}</code> #{html_text(scenario.prompt.truncate(80))} — #{html_text(marks)}"
        "<details>\n<summary>#{summary}</summary>\n\n#{text}\n\n</details>"
      end

      private

      def markdown_title
        scenarios = scenario_keys.size
        "Evaluation — #{scenarios} scenario#{'s' unless scenarios == 1} × #{@models.size} model#{'s' unless @models.size == 1}"
      end

      def scenario_keys
        @results.map { |result| result.scenario.key }.uniq
      end

      def judged_by_line
        label = @judge_label || @judge&.label
        label ? "Judged by `#{label}`." : "No judge; scored on rules and expectations alone."
      end

      # "**Best model: gpt-5-mini**" with the verdict's rationale under it
      # and, when a judge (not the pass-rate ranking) wrote it, who did.
      def verdict_lines
        return [] unless winner

        lines = [ "**Best model: #{winner}**", "" ]
        rationale = verdict["rationale"].to_s.strip
        judge = verdict["judge"].presence
        rationale += " _(#{judge == Report::PASS_RATE_JUDGE ? 'ranked by pass rate' : "judged by #{judge}"})_" if judge && rationale.present?
        lines << rationale << "" if rationale.present?
        lines
      end

      def expectation_lines(scenario)
        lines = []
        lines << "Expects tools: #{scenario.expected_tools.map { |name| "`#{name}`" }.join(' or ')}" if scenario.expected_tools.any?
        lines << "Expects the answer to contain: #{scenario.expected_patterns.map { |text| "`#{text}`" }.join(', ')}" if scenario.expected_patterns.any?
        lines << "Expects the answer not to contain: #{scenario.forbidden_patterns.map { |text| "`#{text}`" }.join(', ')}" if scenario.forbidden_patterns.any?
        lines.map { |line| "- #{line}" }
      end

      def status_mark(result)
        result.passed? ? "✅" : (result.errored? ? "⚠️" : "❌")
      end

      def status_text(result)
        "#{status_mark(result)} #{result.status}"
      end

      def tool_text(tool)
        tool = tool.is_a?(Hash) ? tool.stringify_keys : { "name" => tool.to_s }
        note = tool["note"].presence
        "`#{tool['name']}`#{" (#{note})" if note}"
      end

      # Each line of +text+ as a blockquote line, `<` and `>` escaped so an
      # answer cannot open or close the HTML around it.
      def quoted(text)
        text.to_s.strip.split(/\r?\n/).map { |line| line.strip.empty? ? ">" : "> #{line.gsub('<', '&lt;').gsub('>', '&gt;')}" }
      end

      def html_text(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub(/\s+/, " ")
      end
    end
  end
end
