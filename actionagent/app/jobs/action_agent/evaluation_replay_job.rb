# frozen_string_literal: true

module ActionAgent
  # Replays one scenario under one model for a fanned-out evaluation run
  # (ActionAgent.scenario_evaluation_fan_out) and stores the answer as a
  # pending result; EvaluationJudgeJob scores it. One is enqueued per
  # scenario x model, so the run is as parallel as the :agents queue.
  #
  # A failure outside the replay is stored as the pair's errored result
  # rather than raised, so the run still completes; a scenario removed from
  # the suite during the run is left out of it.
  class EvaluationReplayJob < ApplicationJob
    queue_as :agents

    discard_on ActiveRecord::RecordNotFound

    def perform(run_id, scenario_id, spec, selection = {})
      run = EvaluationRun.find(run_id)
      runner = ScenarioEvaluationRunner.new(run.evaluation, selection: selection, run: run)
      begin
        runner.replay_scenario!(run, scenario_id, spec)
      rescue StandardError => e
        Rails.logger.warn("[ActionAgent] evaluation run #{run_id}: replay of scenario #{scenario_id} failed: #{e.class}: #{e.message}")
        ScenarioEvaluationRunner.new(run.evaluation, selection: selection, run: run).fail_result!(run.reload, scenario_id, spec, e)
      end
    end
  end
end
