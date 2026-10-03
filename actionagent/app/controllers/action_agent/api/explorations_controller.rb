# frozen_string_literal: true

module ActionAgent
  module Api
    # Explorations and the review of their candidate scenarios: listing them,
    # reading one with its candidates, submitting candidates found outside
    # the dashboard, editing, rejecting and accepting candidates, and
    # stopping a walk to review what it found. See Exploration.
    #
    # Everything is scoped to the caller's owner, and another owner's
    # exploration reads as 404. Accepting writes into an evaluation, so it
    # needs :replace_scenarios; storing and editing candidates changes only
    # the exploration.
    class ExplorationsController < BaseController
      include EvaluationRunStarting

      LIST_LIMIT = 50

      before_action :require_owner!
      before_action :set_exploration, except: [ :index, :create ]

      rescue_from Exploration::InvalidCandidate, Exploration::CandidateLimitExceeded, with: :invalid_candidate
      rescue_from Exploration::AcceptRefused, with: :accept_refused
      rescue_from Evaluation::ScenarioLimitExceeded, with: :scenario_limit

      # GET /api/explorations?project_id=&evaluation_id=
      def index
        scope = owned(Exploration).recent
        scope = scope.where(project_id: params[:project_id].to_s) if params[:project_id].present?
        scope = scope.where(evaluation_id: params[:evaluation_id].to_s) if params[:evaluation_id].present?

        render json: { explorations: scope.limit(LIST_LIMIT).map(&:summary) }
      end

      # GET /api/explorations/:id
      def show
        render json: detail(@exploration)
      end

      # POST /api/explorations { project_id: | evaluation_id:, candidates: [...] }
      # Stores candidates an agent outside the dashboard found, as a new
      # exploration with source "external" that is ready for review. An
      # observed agent's evaluation is refused, as the MCP facade's
      # `explorations_submit` refuses it, unless a host adapter replays it.
      def create
        project, evaluation = submission_target
        return if performed?

        exploration = Exploration.build_for(project: project, evaluation: evaluation, user: current_user,
          account: current_account, source: "external", status: "review", started_at: Time.current,
          finished_at: Time.current)
        exploration.save_with_candidates!(candidate_list)

        render json: detail(exploration), status: :created
      end

      # PATCH /api/explorations/:id/candidates/:candidate_id
      # { prompt:, group:, notes: (or rubric:), tools:, contains:, not_contains:, state: }
      # An edit, a rejection (state: "rejected"), or reconsidering a
      # rejected candidate (state: "proposed"); see
      # Exploration#update_candidate!.
      def update_candidate
        candidate = @exploration.update_candidate!(params[:candidate_id], candidate_attributes(params))

        render json: { candidate: candidate, exploration: @exploration.summary }
      end

      # POST /api/explorations/:id/accept { candidate_ids: [...], edits: { id => {...} } }
      # Merges the candidates into the target evaluation (see
      # Exploration#accept!). A refused candidate answers 422 with
      # `problems` keyed by candidate id, and nothing is written.
      def accept
        return unless authorize_action!(:replace_scenarios, @exploration.target_evaluation || @exploration)

        merged = @exploration.accept!(params[:candidate_ids], edits: accept_edits)
        evaluation = merged[:evaluation]

        render json: detail(@exploration.reload).merge(
          accepted: merged.slice(:added, :updated, :unchanged),
          evaluation: evaluation_summary(evaluation)
        )
      end

      # POST /api/explorations/:id/stop
      # Ends a pending or running exploration and keeps what it found for
      # review. 409 once it has stopped.
      def stop
        unless @exploration.stop!(reason: "stopped")
          return render json: { error: "This exploration is not running", status: @exploration.status }, status: :conflict
        end

        render json: detail(@exploration.reload)
      end

      private

      def set_exploration
        @exploration = owned(Exploration).find(params[:id])
      end

      # [project, evaluation] the submission names, one of them nil, or nil
      # after rendering why there is none.
      def submission_target
        if params[:project_id].present?
          [ owned(Project).find(params[:project_id].to_s), nil ]
        elsif params[:evaluation_id].present?
          evaluation = Evaluation.joins(:agent).where(agent: owner_agents).find(params[:evaluation_id].to_s)
          if unexecutable_scenario_run?(evaluation)
            render json: { error: "Observed agents are read-only — duplicate this agent to create an executable copy" },
              status: :unprocessable_entity
            return nil
          end

          [ nil, evaluation ]
        else
          render json: { error: "Name the project_id or evaluation_id the candidates are for" }, status: :bad_request
          nil
        end
      end

      def candidate_list
        list = params[:candidates]
        list.is_a?(Array) ? list.map { |entry| entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry } : list
      end

      # The fields of a candidate edit present in +source+. Nested values
      # arrive as Parameters and are read as plain data by the model.
      def candidate_attributes(source)
        keys = %w[prompt group notes rubric tools contains not_contains expectations state]
        source = source.to_unsafe_h if source.respond_to?(:to_unsafe_h)
        source.is_a?(Hash) ? source.stringify_keys.slice(*keys) : {}
      end

      def accept_edits
        edits = params[:edits]
        edits = edits.to_unsafe_h if edits.respond_to?(:to_unsafe_h)
        return {} unless edits.is_a?(Hash)

        edits.transform_values { |edit| candidate_attributes(edit).except("state") }
      end

      # The exploration with its candidates and what its review shows beside
      # them: the evaluation they merge into, how many candidates to
      # pre-select, and the owner's run allowance.
      def detail(exploration)
        evaluation = exploration.target_evaluation
        usage = ActionAgent.usage_for(current_owner)
        {
          exploration: exploration.summary,
          candidates: exploration.candidates,
          project: exploration.project && { id: exploration.project.id, name: exploration.project.name },
          target_agent: exploration.target_agent && { id: exploration.target_agent.id, name: exploration.target_agent.name },
          evaluation: evaluation_summary(evaluation),
          preselect_limit: ActionAgent.exploration_preselect_limit_for(current_owner),
          runs_remaining: usage[:runs_remaining] || usage["runs_remaining"]
        }
      end

      # What the review needs to estimate a run of the whole suite: the
      # enabled scenarios, and the models each replays under.
      def evaluation_summary(evaluation)
        return nil if evaluation.nil?

        {
          id: evaluation.id,
          name: evaluation.name,
          enabled_scenario_count: evaluation.scenarios.enabled.count,
          model_count: [ evaluation.compare_models.size, 1 ].max
        }
      end

      def invalid_candidate(exception)
        render json: { error: exception.message }, status: :unprocessable_entity
      end

      def accept_refused(exception)
        render json: { error: exception.message, problems: exception.problems }, status: :unprocessable_entity
      end

      def scenario_limit(exception)
        render json: { error: exception.message }, status: :unprocessable_entity
      end
    end
  end
end
