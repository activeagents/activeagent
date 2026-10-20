# frozen_string_literal: true

module ActionAgent
  # Scores, diagnoses and stores one pending result of a fanned-out
  # evaluation run (see EvaluationReplayJob). The job that scores the run's
  # last pending result completes the run.
  #
  # A failure while scoring is stored on the result as an error rather than
  # raised, so the run still completes.
  class EvaluationJudgeJob < ApplicationJob
    queue_as :agents

    discard_on ActiveRecord::RecordNotFound

    def perform(result_id, selection = {}, run_id = nil)
      row = EvaluationScenarioResult.find_by(id: result_id)
      return finish_without_result(run_id, selection) unless row

      run = row.evaluation_run
      begin
        ScenarioEvaluationRunner.new(run.evaluation, selection: selection, run: run).judge_result!(row)
      rescue StandardError => e
        Rails.logger.warn("[ActionAgent] evaluation run #{run.id}: scoring result #{result_id} failed: #{e.class}: #{e.message}")
        ScenarioEvaluationRunner.new(run.evaluation, selection: selection, run: run).fail_judging!(row.reload, e)
      end
    end

    private

    # A result destroyed before it was scored went with its scenario, removed
    # from the suite during the run (EvaluationScenario destroys its results).
    # It may have been the last result the run waited for, so the run's
    # completion is checked without it.
    def finish_without_result(run_id, selection)
      run = run_id && EvaluationRun.find_by(id: run_id)
      ScenarioEvaluationRunner.new(run.evaluation, selection: selection, run: run).finish_fan_out!(run) if run
    end
  end
end
