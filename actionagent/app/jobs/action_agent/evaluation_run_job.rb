# frozen_string_literal: true

module ActionAgent
  # Executes an evaluation run created by Evaluation#run_later!. The run
  # record already exists (pending), so the dashboard can show it while the
  # job is queued; the runner claims it as running, then marks it complete
  # or failed. A job delivered again finds the run claimed and replays
  # nothing, even when two workers load it as pending at once.
  class EvaluationRunJob < ApplicationJob
    queue_as :agents

    def perform(evaluation_id, run_id, selection = {})
      evaluation = Evaluation.find(evaluation_id)
      run = evaluation.evaluation_runs.find(run_id)
      return unless run.pending?

      evaluation.run!(run: run, **selection.to_h.symbolize_keys)
    end
  end
end
