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

    def perform(result_id, selection = {})
      row = EvaluationScenarioResult.find(result_id)
      run = row.evaluation_run
      begin
        ScenarioEvaluationRunner.new(run.evaluation, selection: selection, run: run).judge_result!(row)
      rescue StandardError => e
        Rails.logger.warn("[ActionAgent] evaluation run #{run.id}: scoring result #{result_id} failed: #{e.class}: #{e.message}")
        ScenarioEvaluationRunner.new(run.evaluation, selection: selection, run: run).fail_judging!(row.reload, e)
      end
    end
  end
end
