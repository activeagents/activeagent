# frozen_string_literal: true

module ActionAgent
  class AgentExecutionJob < ApplicationJob
    queue_as :agents

    def perform(run_id)
      run = AgentRun.find(run_id)
      return if run.cancelled? || run.complete?

      run.update!(status: :running, started_at: Time.current)
      run.add_log("Starting execution", level: :info)

      begin
        agent_record = run.agent

        # Build the agent class dynamically based on configuration
        result = execute_agent(agent_record, run)

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

      rescue => e
        run.update!(
          status: :failed,
          completed_at: Time.current,
          error_message: e.message,
          error_backtrace: e.backtrace&.first(10)&.join("\n")
        )
        run.add_log("Execution failed: #{e.message}", level: :error)
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
