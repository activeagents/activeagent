# frozen_string_literal: true

require "stringio"
require "zlib"

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
    #
    # A batch may be sent gzipped, with Content-Encoding: gzip, as a sandbox's
    # browser sends it. It is inflated no further than the batch size limit.
    class RecordingEventIngestController < ActionController::API
      wrap_parameters false

      def create
        recording = SessionRecording.find_by(id: request.path_parameters[:id])
        unless recording&.ingest_token_valid?(bearer_token)
          return render(json: { error: "Invalid or expired recording token" }, status: :unauthorized)
        end

        body = batch_body
        return if performed?

        result = RecordingEventIngest.call(recording, body)
        render json: result.body, status: result.status
      end

      private

      # The request body, inflated when it was gzipped. Renders the refusal
      # instead when the encoding is unsupported, the gzip is damaged, or it
      # inflates past the batch size limit.
      def batch_body
        encoding = request.headers["Content-Encoding"].to_s.strip.downcase
        return request.raw_post if encoding.empty? || encoding == "identity"
        unless encoding == "gzip"
          return render(json: { error: "Content-Encoding must be gzip or identity" }, status: :unsupported_media_type)
        end

        limit = RecordingEvent.limits[:batch_bytes]
        inflated = Zlib::GzipReader.new(StringIO.new(request.raw_post)).read(limit + 1).to_s
        if inflated.bytesize > limit
          return render(json: { error: "The batch is over the limit of #{limit} bytes", code: "recording_limit" },
            status: RecordingEventIngest::PAYLOAD_TOO_LARGE)
        end

        inflated.force_encoding(Encoding::UTF_8)
      rescue Zlib::Error
        render json: { error: "The body is not valid gzip" }, status: :bad_request
      end

      def bearer_token
        request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]
      end
    end
  end
end
