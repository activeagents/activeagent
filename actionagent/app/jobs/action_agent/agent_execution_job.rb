# frozen_string_literal: true

module ActionAgent
  class AgentExecutionJob < ApplicationJob
    queue_as :agents

    def perform(run_id)
      run = AgentRun.find(run_id)
      # Anything already finished — complete, failed or cancelled — is never
      # executed again. A retry of a failed run would re-run the generation.
      return if run.finished?

      run.update!(status: :running, started_at: Time.current)
      run.add_log("Starting execution", level: :info)

      begin
        agent_record = run.agent

        # Build the agent class dynamically based on configuration
        result = execute_agent(agent_record, run)

        finish_unless_cancelled(run) do
          run.update!(
            output: result[:output],
            output_metadata: result[:metadata],
            status: :complete,
            completed_at: Time.current,
            duration_ms: ((Time.current - run.started_at) * 1000).to_i,
            input_tokens: result.dig(:usage, :input_tokens),
            output_tokens: result.dig(:usage, :output_tokens),
            total_tokens: result.dig(:usage, :total_tokens)
          )
          run.add_log("Execution completed successfully", level: :info)
        end
      rescue => e
        finish_unless_cancelled(run) do
          run.update!(
            status: :failed,
            completed_at: Time.current,
            error_message: e.message,
            error_backtrace: e.backtrace&.first(10)&.join("\n")
          )
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

    # A cancel that arrived while the service was running must survive it:
    # the run's terminal state is written under a row lock after re-reading
    # the status, so a cancelled run is never flipped back to complete or
    # failed by the job that was still executing it.
    def finish_unless_cancelled(run)
      run.with_lock do
        if run.cancelled?
          run.add_log("Execution finished after cancellation; result discarded", level: :info)
          return
        end

        yield
      end
    end
  end
end
