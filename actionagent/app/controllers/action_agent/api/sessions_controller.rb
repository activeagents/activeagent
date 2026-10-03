# frozen_string_literal: true

module ActionAgent
  module Api
    # Timelines of sessions that need no recording: a conversation, a run,
    # or the run that replayed an evaluation scenario. Each adds the browser
    # lane of any recording linked to it. See SessionTimeline.
    class SessionsController < BaseController
      # GET /api/sessions/:kind/:id/timeline, where +kind+ is context, run or
      # scenario_result.
      def timeline
        timeline =
          case params[:kind]
          when "context" then SessionTimeline.for_context(owned_context, timeline_scope)
          when "run" then SessionTimeline.for_run(owned_run(params[:id]), timeline_scope)
          when "scenario_result" then SessionTimeline.for_run(scenario_result_run, timeline_scope)
          end

        render json: { timeline: timeline.retitle(params[:kind], integer_param(:id)).as_json }
      end

      private

      def owned_context
        AgentContext.for_agents(owner_agents).find(params[:id])
      end

      def owned_run(id)
        AgentRun.where(agent: owner_agents).find(id)
      end

      # The run a scenario result was replayed by. A result belongs to the
      # caller through its evaluation's agent.
      def scenario_result_run
        evaluations = Evaluation.where(agent: owner_agents)
        result = EvaluationScenarioResult
          .where(evaluation_run: EvaluationRun.where(evaluation: evaluations))
          .find(params[:id])
        raise ActiveRecord::RecordNotFound unless result.agent_run_id

        owned_run(result.agent_run_id)
      end
    end
  end
end
