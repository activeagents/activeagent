# frozen_string_literal: true

module ActiveAgent
  module Evals
    # The outcome of one evaluation run: every scenario × model Result, a summary
    # per model, criterion statistics, the faults grouped with the fix each
    # calls for, and the model that did best. Renders as a hash, JSON, or
    # Markdown.
    class Report
      attr_reader :results, :models, :judge, :instructions, :metadata

      def initialize(results:, models:, judge: nil, instructions: nil, threshold: PASS_THRESHOLD, metadata: {})
        @results = results
        @models = models
        @judge = judge
        @instructions = instructions
        @threshold = threshold
        @metadata = metadata
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

      # The best model when comparing: highest pass rate, then mean score, then
      # lowest cost, with the judge's rationale when one is available.
      # `{ "winner", "rationale", "judge" }`, or nil for a single model.
      def verdict
        return nil unless comparing?

        @verdict ||= begin
          ranked = summary_by_model.sort_by do |_label, stats|
            [ -stats["pass_rate"].to_f, -stats["avg_score"].to_f, stats["cost"].to_f ]
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

      # A self-contained HTML report — inline styles, no external assets — so
      # a run's outcome can be archived or shared the way a CI test report is.
      # Same content as +to_markdown+: per-model summaries, the verdict, the
      # scenario × model matrix grouped the way the suite groups its
      # scenarios, recommendations, and every answer behind a disclosure.
      def to_html
        scenario_count = @results.map { |result| result.scenario.key }.uniq.size
        title = "Evaluation — #{scenario_count} scenario#{'s' unless scenario_count == 1} × #{@models.size} model#{'s' unless @models.size == 1}"

        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{h(title)}</title>
          <style>#{HTML_STYLES}</style>
          </head>
          <body>
          <div class="wrap">
          <h1>#{h(title)}</h1>
          <p class="judge-line">#{@judge ? "Judged by <code>#{h(@judge.label)}</code>" : 'No judge; scored on rules and expectations alone'}#{html_metadata}</p>
          #{html_summary_cards}
          #{html_verdict}
          #{html_matrix}
          #{html_recommendations}
          #{html_details}
          </div>
          </body>
          </html>
        HTML
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
          "| `#{key}` #{cohort.first.scenario.prompt.truncate(70)} | #{cells.join(' | ')} |"
        end
        header + rows
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

      # --- HTML rendering -------------------------------------------------

      HTML_STYLES = <<~CSS.freeze
        :root { color-scheme: light; }
        body { font-family: -apple-system, "Segoe UI", Roboto, sans-serif; margin: 0; background: #f8fafc; color: #0f172a; }
        .wrap { max-width: 1100px; margin: 0 auto; padding: 32px 40px 80px; background: #fff; min-height: 100vh; }
        h1 { font-size: 24px; border-bottom: 2px solid #ef4444; padding-bottom: 10px; }
        h2 { font-size: 19px; margin-top: 36px; border-bottom: 1px solid #e2e8f0; padding-bottom: 6px; }
        code { background: #f1f5f9; padding: 1px 5px; border-radius: 4px; font-size: 12px; font-family: ui-monospace, monospace; }
        .judge-line { color: #475569; }
        .meta { display: inline-block; margin-left: 8px; padding: 2px 8px; border-radius: 999px; background: #f1f5f9; font-size: 12px; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 12px; margin: 16px 0; }
        .card { border: 1px solid #e2e8f0; border-radius: 10px; padding: 12px 14px; }
        .card.winner { border-color: #22c55e; }
        .card .model { font-family: ui-monospace, monospace; font-size: 12px; word-break: break-all; }
        .card .rate { font-size: 26px; font-weight: 700; }
        .rate.good { color: #16a34a; } .rate.mid { color: #ca8a04; } .rate.bad { color: #dc2626; }
        .card .stats, .card .faults { font-size: 12px; color: #475569; }
        .verdict { border-left: 3px solid #22c55e; background: #f0fdf4; border-radius: 0 8px 8px 0; padding: 10px 14px; margin: 12px 0; }
        .verdict .who { font-weight: 700; }
        .verdict .via { color: #64748b; font-size: 12px; }
        .scroll { overflow-x: auto; }
        table { border-collapse: collapse; width: 100%; font-size: 13px; }
        th, td { border: 1px solid #e2e8f0; padding: 6px 10px; text-align: left; vertical-align: top; }
        th { background: #f8fafc; }
        td.group { background: #f8fafc; font-weight: 600; }
        .pass { color: #16a34a; } .fail { color: #dc2626; } .err { color: #ca8a04; }
        .fault-label { color: #64748b; }
        .prompt-key { font-family: ui-monospace, monospace; font-size: 11px; color: #64748b; margin-right: 6px; }
        details { border: 1px solid #e2e8f0; border-radius: 8px; margin: 8px 0; padding: 0 12px; }
        details summary { cursor: pointer; padding: 8px 0; font-family: ui-monospace, monospace; font-size: 12px; }
        blockquote { border-left: 3px solid #cbd5e1; margin: 8px 0; padding: 2px 12px; color: #475569; }
        .answer { white-space: pre-wrap; font-size: 13px; }
        .recommendation { border-left: 3px solid #ef4444; background: #fef2f2; border-radius: 0 8px 8px 0; padding: 8px 12px; margin: 8px 0; }
        .recommendation .count { font-weight: 700; }
        .recommendation .scenarios { color: #64748b; font-size: 12px; }
      CSS

      def h(value)
        CGI.escapeHTML(value.to_s)
      end

      def html_metadata
        @metadata.to_h.map { |key, value| %( <span class="meta">#{h(key)}: #{h(value)}</span>) }.join
      end

      def html_summary_cards
        cards = summary_by_model.map do |label, stats|
          tone = stats["pass_rate"] >= 85 ? "good" : (stats["pass_rate"] >= 60 ? "mid" : "bad")
          faults = stats["faults"].map { |fault, count| "#{h(fault.tr('_', ' '))} ×#{count}" }.join(" · ")
          <<~CARD
            <div class="card#{' winner' if winner == label}">
              <div class="model">#{h(label)}</div>
              <div class="rate #{tone}">#{stats['pass_rate']}%</div>
              <div class="stats">#{stats['passed']}/#{stats['scenarios']} passed · score #{stats['avg_score'] || '—'} ·
                #{stats['avg_duration_ms'] ? "#{stats['avg_duration_ms']} ms" : '—'} ·
                #{stats['input_tokens']}/#{stats['output_tokens']} tok ·
                #{stats['cost'] ? format('$%.4f', stats['cost']) : '—'}</div>
              #{"<div class=\"faults\">#{faults}</div>" if faults.present?}
            </div>
          CARD
        end
        %(<div class="cards">#{cards.join}</div>)
      end

      def html_verdict
        return "" unless verdict

        <<~BANNER
          <div class="verdict">
            <span class="who">Winner: #{h(verdict['winner'])}</span>
            <span class="via">judged by #{h(verdict['judge'])}</span>
            <div>#{h(verdict['rationale'])}</div>
          </div>
        BANNER
      end

      def html_matrix
        labels = @models.map(&:label)
        head = "<tr><th>Scenario</th>#{labels.map { |label| "<th><code>#{h(label)}</code></th>" }.join}</tr>"
        rows = +""
        current_group = :none
        @results.group_by { |result| result.scenario.key }.each_value do |cohort|
          scenario = cohort.first.scenario
          if scenario.group != current_group
            current_group = scenario.group
            group_name = scenario.group_name.presence || scenario.group
            rows << %(<tr><td class="group" colspan="#{labels.size + 1}">#{h(group_name)}</td></tr>) if group_name
          end
          cells = labels.map do |label|
            result = cohort.find { |candidate| candidate.label == label }
            next "<td>—</td>" unless result

            tone, mark = result.passed? ? %w[pass ✓] : (result.errored? ? %w[err ⚠] : %w[fail ✗])
            fault = result.fault ? %( <span class="fault-label">· #{h(result.fault.tr('_', ' '))}</span>) : ""
            %(<td><span class="#{tone}">#{mark} #{result.score&.round(2)}</span>#{fault}</td>)
          end
          rows << %(<tr><td><span class="prompt-key">#{h(scenario.key)}</span>#{h(scenario.prompt.truncate(90))}</td>#{cells.join}</tr>)
        end
        %(<div class="scroll"><table>#{head}#{rows}</table></div>)
      end

      def html_recommendations
        return "" if recommendations.empty?

        entries = recommendations.map do |entry|
          tools = entry["suggested_tools"].map { |tool| "<li><code>#{h(tool['name'])}</code> — #{h(tool['description'])}</li>" }.join
          <<~ENTRY
            <div class="recommendation">
              <span class="count">#{h(entry['fault'].tr('_', ' '))} ×#{entry['count']}</span>
              <span class="scenarios">#{h(entry['scenario_keys'].join(', '))} · #{h(entry['models'].join(', '))}</span>
              <div>#{h(entry['recommendation'])}</div>
              #{"<ul>#{tools}</ul>" if tools.present?}
            </div>
          ENTRY
        end
        %(<h2>Recommendations</h2>#{entries.join})
      end

      def html_details
        blocks = @results.map do |result|
          tone = result.passed? ? "pass" : (result.errored? ? "err" : "fail")
          tools = result.replay.tool_calls.map { |call| "<code>#{h(call['name'])}#{' ✗' if call['error']}</code>" }.join(" ")
          fault = result.fault ? %(<div><strong>#{h(result.fault.tr('_', ' '))}</strong> — #{h(result.summary)} #{h(result.recommendation)}</div>) : ""
          error = result.replay.error ? %(<div class="fail">Error: #{h(result.replay.error.to_s.truncate(500))}</div>) : ""
          <<~BLOCK
            <details>
              <summary><span class="#{tone}">#{result.passed? ? '✓' : (result.errored? ? '⚠' : '✗')}</span>
                #{h(result.scenario.key)} · #{h(result.label)}#{" · score #{result.score.round(2)}" if result.score}</summary>
              <blockquote>#{h(result.scenario.prompt)}</blockquote>
              #{"<div>Tools: #{tools}</div>" if tools.present?}
              #{fault}
              #{error}
              <p class="answer">#{h((result.replay.answer.presence || '(no answer)').to_s.truncate(3_000))}</p>
            </details>
          BLOCK
        end
        %(<h2>Answers</h2>#{blocks.join})
      end
    end
  end
end
