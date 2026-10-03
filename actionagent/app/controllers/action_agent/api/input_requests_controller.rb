# frozen_string_literal: true

module ActionAgent
  module Api
    # The requests for input paused runs are waiting on, and the answers that
    # resume them.
    #
    # Every request is read through `owned`, so one outside the caller's
    # owner scope answers 404. Answering or declining asks
    # ActionAgent.permitted? about :answer_input_request (403 when denied),
    # and the request must still be pending and unexpired (409).
    class InputRequestsController < BaseController
      LIST_LIMIT = 100

      before_action :require_owner!
      before_action :set_input_request, only: [ :answer, :decline ]
      before_action :authorize_answer!, only: [ :answer, :decline ]

      # GET /api/input_requests
      #
      # Pending requests unless `status` names another (or `all`), filtered by
      # `agent_id` and `run_id`, newest first.
      def index
        scope = owned(InputRequest).includes(:subject).recent
        status = params[:status].presence || "pending"
        unless status == "all"
          return render json: { error: "Unknown status #{status.to_s.truncate(32)}" }, status: :bad_request unless InputRequest.statuses.key?(status)

          scope = scope.where(status: status)
        end
        scope = scope.where(subject_type: AgentRun.polymorphic_name, subject_id: params[:run_id].to_s) if params[:run_id].present?
        if params[:agent_id].present?
          scope = scope.where(subject_type: AgentRun.polymorphic_name, subject_id: AgentRun.where(agent_id: params[:agent_id].to_s).select(:id))
        end

        render json: { input_requests: scope.limit(LIST_LIMIT).map { |request| InputRequestSerializer.call(request) } }
      end

      # POST /api/input_requests/:id/answer
      #
      # `answer` is the answer. A `confirm` request is approved by `true` or
      # by no answer, and declined by `false`.
      def answer
        settle { @input_request.answer!(params[:answer], user: current_user) }
      end

      # POST /api/input_requests/:id/decline
      def decline
        settle { @input_request.decline!(user: current_user) }
      end

      private

      def set_input_request
        @input_request = owned(InputRequest).find(params[:id])
      end

      def authorize_answer!
        permission_denied(:answer_input_request) unless @input_request.answerable_by?(current_user)
      end

      def settle
        yield
        render json: { input_request: InputRequestSerializer.call(@input_request) }
      rescue InputRequest::Conflict => e
        render json: { error: e.message, code: "conflict", status: @input_request.reload.status }, status: :conflict
      rescue InputRequest::InvalidAnswer => e
        render json: { error: e.message, code: "invalid_answer" }, status: :unprocessable_entity
      end
    end
  end
end
