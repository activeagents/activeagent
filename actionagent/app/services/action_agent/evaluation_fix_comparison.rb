# frozen_string_literal: true

module ActionAgent
  class EvaluationFixComparison
    def initialize(session)
      @session = session
    end

    def self.change(before, after)
      return "pending" unless after
      return after.passed? ? "added_pass" : "added_fail" unless before
      return after.passed? ? "unchanged_pass" : "regressed" if before.passed?
      after.passed? ? "fixed" : "still_failing"
    end

    def rows
      before = indexed(@session.evaluation_run)
      after = indexed(@session.verification_run)
      (before.keys | after.keys).map do |key|
        first, last = before[key], after[key]
        { scenario_key: key[0], model: key[1], change: self.class.change(first, last),
          before: first&.status, after: last&.status, before_score: first&.score&.to_f, after_score: last&.score&.to_f,
          score_change: first&.score && last&.score ? (last.score - first.score).to_f.round(3) : nil,
          before_fault: first&.fault, fault: last&.fault }
      end
    end

    def summary
      { run_id: @session.verification_run_id, status: @session.verification_run&.status,
        error: @session.verification_error || @session.verification_run&.error_message,
        counts: rows.group_by { |row| row[:change] }.transform_values(&:size), rows: rows }
    end

    def pull_request_body(mount:)
      base = @session.evaluation_run
      title = @session.fix_item["quote"].presence || @session.fix_item["fault"].to_s.humanize
      lines = [ "## Evaluation fix", title, "",
        "[Original run](#{mount}/evaluations/#{base.evaluation_id}/runs/#{base.id})",
        "[Verification run](#{mount}/evaluations/#{base.evaluation_id}/runs/#{@session.verification_run_id})", "",
        "| Scenario / model | Before | After | Score change | Fault |", "| --- | --- | --- | --- | --- |" ]
      rows.each do |row|
        cells = [ "#{row[:scenario_key]} / #{row[:model]}", row[:before], row[:after] || "pending", row[:score_change], row[:fault] || "—" ]
        lines << "| #{cells.map { |cell| cell.to_s.gsub('|', '\\|').gsub(/[\r\n]/, ' ') }.join(' | ')} |"
      end
      lines += [ "", "## Session summary", @session.result.to_s, "", "Code session ##{@session.id}. Review the diff and full-suite regressions before merging." ]
      SecretScrubber.scrub(lines.join("\n"), @session.secrets)
    end

    private

    def indexed(run)
      return {} unless run
      item = @session.fix_item || {}
      run.scenario_results.includes(:scenario).each_with_object({}) do |result, index|
        key = result.evaluated_scenario["key"]
        model = [ result.provider, result.model ].compact_blank.join("/")
        next unless Array(item["scenario_keys"]).include?(key) &&
          (Array(item["models"]).include?(model) || Array(item["models"]).include?(result.model))
        index[[ key, model ]] = result
      end
    end
  end
end
