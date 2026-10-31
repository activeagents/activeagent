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

    # Moves the run from pending to running in one conditional update, as
    # CodeSessionJob#start claims a session, and returns whether this job is
    # the one that did. The write checks the status itself, so of two
    # workers that loaded the run as pending only the first to write
    # executes it, and the other starts no generation, on every database. A
    # read under the row lock followed by a write would be refused on SQLite
    # with Rails 7.2, whose deferred transactions cannot write once another
    # writer has committed. Nothing is held over the generation, so a cancel
    # never waits for it. The update skips callbacks, so the status change is
    # broadcast here.
    def claim_pending(run)
      now = Time.current
      claimed = AgentRun.where(id: run.id, status: AgentRun.statuses[:pending])
        .update_all(status: AgentRun.statuses[:running], started_at: now, updated_at: now)
      return false if claimed.zero?

      run.reload
      run.broadcast_update
      true
    end

    def execute_agent(agent_record, run)
      AgentExecutionService.call(agent_record, run)
    end
  end
end
