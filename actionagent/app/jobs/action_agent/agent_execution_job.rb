# frozen_string_literal: true

module ActionAgent
  class AgentExecutionJob < ApplicationJob
    queue_as :agents

    def perform(run_id)
      run = AgentRun.find(run_id)
      # Only a pending run is executed. A finished run (complete, failed or
      # cancelled) is never executed again, a run waiting for input only
      # AgentResumeJob continues, and a running run already has a worker. A
      # retry of a failed run would re-run the generation.
      return unless claim_pending(run)

      run.add_log("Starting execution", level: :info)

      begin
        agent_record = run.agent

        # Build the agent class dynamically based on configuration
        result = execute_agent(agent_record, run)

        run.unless_cancelled do
          run.record_result!(result, segment_started_at: run.started_at)
          run.add_log(result[:input_requests].present? ? "Execution paused for input" : "Execution completed successfully", level: :info)
        end
      rescue => e
        run.unless_cancelled do
          run.record_failure!(e)
          run.add_log("Execution failed: #{e.message}", level: :error)
        end
        raise
      ensure
        run.broadcast_update
      end
    end

    private

    # Moves the run from pending to running under its row lock and returns
    # whether this job is the one that did. The status is read again inside
    # the lock, so of two workers that loaded the run as pending only the
    # first to take the lock executes it, and the other starts no
    # generation. The lock is held for the status change alone, not for the
    # generation, so a cancel is never made to wait for it.
    def claim_pending(run)
      run.with_lock do
        next false unless run.pending?

        run.update!(status: :running, started_at: Time.current)
        true
      end
    end

    def execute_agent(agent_record, run)
      AgentExecutionService.call(agent_record, run)
    end
  end
end
