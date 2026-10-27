# frozen_string_literal: true

module ActionAgent
  module Api
    # Server-to-server submission; end-user apps authenticate their own users
    # and proxy feedback rather than exposing the ingest key in a browser.
    class FeedbackIngestController < ActionController::API
      include IngestAuthentication

      def create
        envelope = params.require(:feedback)
        raise ActionController::ParameterMissing, :feedback unless envelope.is_a?(ActionController::Parameters)

        input = envelope.permit(:trace_id, :feedback_id, :rating, :comment, :span_id, :user_reference)
        trace = ActionAgent.trace_model.for_account(@account).find_by!(trace_id: input.delete(:trace_id))
        record = nil
        # Serialize concurrent changes and use the unique index for first-write
        # races. Reusing an ID deliberately replaces the prior rating/comment.
        trace.with_lock do
          record = InteractionFeedback.find_or_initialize_by(
            telemetry_trace_id: trace.id, feedback_id: input[:feedback_id])
          record.update!(input)
        end
        render json: { feedback: record.as_json }, status: :ok
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Trace not found; retry after trace ingestion completes" }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
      rescue ActionController::ParameterMissing => e
        render json: { error: e.message }, status: :bad_request
      end
    end
  end
end
