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
