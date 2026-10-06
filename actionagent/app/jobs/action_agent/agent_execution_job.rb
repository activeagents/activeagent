# frozen_string_literal: true

module ActionAgent
  class AgentExecutionJob < ApplicationJob
    queue_as :agents

    def perform(run_id)
      run = AgentRun.find(run_id)
      # Anything already finished — complete, failed or cancelled — is never
      # executed again, and neither is a run waiting for input, which only
      # AgentResumeJob continues. A retry of a failed run would re-run the
      # generation.
      return if run.finished? || run.awaiting_input?

      run.update!(status: :running, started_at: Time.current)
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

    def execute_agent(agent_record, run)
      AgentExecutionService.call(agent_record, run)
    end
  end
end
