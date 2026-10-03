# frozen_string_literal: true

module ActionAgent
  module Api
    # The sessions a caller can replay (SessionIndex), and the timelines of
    # sessions that need no recording: a conversation, a run, or the run that
    # replayed an evaluation scenario. Each timeline adds the browser lane of
    # any recording linked to it. See SessionTimeline.
    class SessionsController < BaseController
      # A filter value the index cannot read.
      class InvalidFilter < ArgumentError; end

      before_action :require_owner!, only: :index

      # GET /api/sessions
      #
      # Parameters, each optional:
      #   agent_id  one of the caller's agents
      #   user      "me": sessions whose runs ran on behalf of the signed-in user
      #   source    dashboard, evaluation or agent
      #   outcome   failed or passed
      #   from, to  last activity in [from, to), ISO 8601 times or dates
      #   before    the next_before of the previous page
      #   per_page  25 by default, at most 100
      def index
        index = SessionIndex.new(
          agents: owner_agents, recordings: reachable_recordings, filters: index_filters,
          per_page: clamped_param(:per_page, default: SessionIndex::DEFAULT_PER_PAGE, min: 1, max: SessionIndex::MAX_PER_PAGE),
          before: params[:before].is_a?(String) ? params[:before] : nil
        )
        render json: index.as_json
      rescue InvalidFilter, SessionIndex::InvalidCursor => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/sessions/:kind/:id/timeline, where +kind+ is context, run or
      # scenario_result.
      def timeline
        timeline =
          case params[:kind]
          when "context" then SessionTimeline.for_context(owned_context, timeline_scope)
          when "run" then SessionTimeline.for_run(owned_run(params[:id]), timeline_scope)
          when "scenario_result" then SessionTimeline.for_run(scenario_result_run, timeline_scope)
          end

        render json: RecordingEvent.generate_json(timeline: timeline.retitle(params[:kind], integer_param(:id)).as_json)
      end

      private

      def index_filters
        SessionIndex::Filters.new(
          agent_id: integer_param(:agent_id),
          actor: choice_param(:user, %w[me]) ? current_user || SessionIndex::NO_ACTOR : nil,
          source: choice_param(:source, SessionIndex::SOURCES),
          outcome: choice_param(:outcome, SessionIndex::OUTCOMES),
          from: time_param(:from),
          to: time_param(:to)
        )
      end

      # +name+'s value when it is one of +choices+, nil when absent.
      # @raise [InvalidFilter] for any other value
      def choice_param(name, choices)
        value = params[name]
        return nil if value.blank?
        return value if value.is_a?(String) && choices.include?(value)

        raise InvalidFilter, "#{name} must be one of: #{choices.join(', ')}"
      end

      # +name+ as a Time: an ISO 8601 time, or a date read as its first moment
      # in the app's time zone. Nil when absent.
      # @raise [InvalidFilter] for anything else
      def time_param(name)
        value = params[name]
        return nil if value.blank?
        raise ArgumentError unless value.is_a?(String)

        value.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(value).in_time_zone : Time.iso8601(value)
      rescue ArgumentError
        raise InvalidFilter, "#{name} must be an ISO 8601 time or date"
      end

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
