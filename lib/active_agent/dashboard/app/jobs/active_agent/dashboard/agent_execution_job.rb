# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Background job for executing agent runs.
    #
    # Handles the actual execution of an agent with the given input,
    # updating the AgentRun record with results.
    #
    class AgentExecutionJob < ApplicationJob
      queue_as :default

      def perform(agent_run_id)
        run = AgentRun.find(agent_run_id)
        return if run.finished?

        run.update!(status: :running, started_at: Time.current)

        begin
          agent = run.agent
          result = execute_agent(agent, run.input_prompt, **(run.input_params || {}))

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
        rescue => e
          run.update!(
            status: :failed,
            completed_at: Time.current,
            error_message: e.message,
            error_backtrace: e.backtrace&.first(10)&.join("\n")
          )
        end
      end

      private

      def execute_agent(agent, input_prompt, **params)
        # TODO: Build and execute actual ActiveAgent::Base subclass
        # For now, return mock data
        {
          output: "Executed: #{input_prompt}",
          metadata: { provider: agent.provider, model: agent.model },
          usage: { input_tokens: 100, output_tokens: 200, total_tokens: 300 }
        }
      end
    end
  end
end
