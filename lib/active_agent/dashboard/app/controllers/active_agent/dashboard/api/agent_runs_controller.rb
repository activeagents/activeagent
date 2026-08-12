# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    module Api
      class AgentRunsController < BaseController
        before_action :set_run, only: [ :show, :cancel ]

        # GET /api/runs/:id
        def show
          render json: {
            run: run_json(@run),
            messages: interaction_messages(@run),
            agent: {
              id: @run.agent.id,
              name: @run.agent.name,
              slug: @run.agent.slug
            }
          }
        end

        # POST /api/runs/:id/cancel
        def cancel
          @run.cancel!
          render json: { run: @run.summary }
        end

        # GET /api/runs
        def index
          # Scoped to the caller's own agents: this listed (and counted) every
          # run in the database regardless of who owned it.
          scope = AgentRun.includes(:agent).where(agent: owner_agents).recent

          scope = scope.where(agent_id: params[:agent_id]) if params[:agent_id].present?
          scope = scope.where(status: params[:status]) if params[:status].present?

          page = (params[:page] || 1).to_i
          per_page = (params[:per_page] || 20).to_i
          total = scope.count
          runs = scope.offset((page - 1) * per_page).limit(per_page)

          render json: {
            runs: runs.map { |run| run_json(run, include_agent: true) },
            meta: {
              page: page,
              per_page: per_page,
              total: total
            }
          }
        end

        private

        def set_run
          @run = AgentRun.where(agent: owner_agents).find(params[:id])
        end

        # The run's slice of its agent's conversation stream, for the shared
        # InteractionStream UI. User messages carry the run's trace_id in
        # provenance (SolidAgent::HasContext); the slice spans from this run's
        # user message up to the next user message with a different trace_id.
        # Prepended with the system instructions the run executed under
        # (captured in output_metadata; falls back to the agent's current ones).
        def interaction_messages(run)
          return [] if run.trace_id.blank?

          context = AgentContext.for_agents(Agent.where(id: run.agent_id)).order(created_at: :desc).first
          return [] unless context

          messages = context.messages.chronological.to_a
          start_index = messages.index do |message|
            message.role == "user" && message.provenance&.dig("trace_id") == run.trace_id
          end
          return [] unless start_index

          slice = [ messages[start_index] ]
          messages[(start_index + 1)..].each do |message|
            trace = message.provenance&.dig("trace_id")
            break if message.role == "user" && trace.present? && trace != run.trace_id

            slice << message
          end

          serialized = slice.map { |message| AgentMessageSerializer.call(message) }
          instructions = run.output_metadata&.dig("instructions").presence || run.agent.instructions
          if instructions.present?
            serialized.unshift(
              id: "run-#{run.id}-system",
              role: "system",
              content: instructions,
              created_at: (run.started_at || run.created_at).iso8601(3)
            )
          end
          serialized
        end

        def run_json(run, include_agent: false)
          json = {
            id: run.id,
            status: run.status,
            input_prompt: run.input_prompt,
            input_params: run.input_params,
            output: run.output,
            output_metadata: run.output_metadata,
            duration_ms: run.calculated_duration_ms,
            input_tokens: run.input_tokens,
            output_tokens: run.output_tokens,
            total_tokens: run.total_tokens,
            error_message: run.error_message,
            trace_id: run.trace_id,
            logs: run.logs,
            started_at: run.started_at,
            completed_at: run.completed_at,
            created_at: run.created_at
          }

          if include_agent
            json[:agent] = {
              id: run.agent.id,
              name: run.agent.name,
              slug: run.agent.slug
            }
          end

          json
        end
      end
    end
  end
end
