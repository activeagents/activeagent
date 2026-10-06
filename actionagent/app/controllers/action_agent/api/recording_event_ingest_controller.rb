# frozen_string_literal: true

module ActionAgent
  module Api
    # POST <mount>/api/session_recordings/:id/events with a recording's
    # ingest token as the bearer token: a recorder outside the dashboard,
    # such as a sandbox's browser, posting a batch of events
    # (RecordingEventIngest).
    #
    # The token authenticates on its own, so this is not a dashboard
    # controller and sees no session, no forgery protection and none of the
    # host's controller concerns. It is accepted only for the recording it
    # was issued for, while SessionRecording#ingest_token_valid? holds, and
    # only for RecordingEvent::CLIENT_KINDS. It reads nothing back. A request
    # without a bearer token is routed to SessionRecordingsController#create_events.
    class RecordingEventIngestController < ActionController::API
      wrap_parameters false

      def create
        recording = SessionRecording.find_by(id: request.path_parameters[:id])
        unless recording&.ingest_token_valid?(bearer_token)
          return render(json: { error: "Invalid or expired recording token" }, status: :unauthorized)
        end

        result = RecordingEventIngest.call(recording, request.raw_post)
        render json: result.body, status: result.status
      end

      private

      def bearer_token
        request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]
      end
    end
  end
end
