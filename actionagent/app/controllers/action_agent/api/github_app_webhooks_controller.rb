# frozen_string_literal: true

require "openssl"

module ActionAgent
  module Api
    # POST <mount>/api/github_app/webhooks: the GitHub App's webhook
    # deliveries (installation, installation_repositories,
    # github_app_authorization), applied by GithubWebhookJob.
    #
    # GitHub's signature authenticates a delivery on its own, so this is not a
    # dashboard controller and sees no session, no forgery protection and none
    # of the host's controller concerns. A delivery is accepted only when its
    # X-Hub-Signature-256 is the HMAC-SHA256 of the raw body under
    # ActionAgent.github_app_webhook_secret; with no secret configured there
    # is no endpoint (404).
    #
    # The answer is 202 as soon as a delivery is recorded and enqueued, or
    # recognized as one already recorded (GithubWebhookDelivery), or found to
    # be an event the dashboard does not handle. Only a failure to enqueue
    # answers otherwise, and leaves the delivery unrecorded so a redelivery
    # of it is processed.
    #
    # The body may be JSON, or a form whose +payload+ field holds the JSON,
    # as GitHub sends it when the App's content type is
    # application/x-www-form-urlencoded. The signature covers the raw body
    # either way.
    class GithubAppWebhooksController < ActionController::API
      wrap_parameters false

      SIGNATURE_HEADER = "X-Hub-Signature-256"
      EVENT_HEADER = "X-GitHub-Event"
      DELIVERY_HEADER = "X-GitHub-Delivery"

      def create
        secret = ActionAgent.github_app_webhook_secret
        return head(:not_found) if secret.blank?

        body = request.raw_post.to_s
        unless signed?(body, secret)
          return render(json: { error: "Invalid or missing #{SIGNATURE_HEADER}" }, status: :unauthorized)
        end

        event = request.headers[EVENT_HEADER].to_s
        return accepted("ignored") unless event.in?(GithubWebhookJob::EVENTS)

        delivery_id = request.headers[DELIVERY_HEADER].to_s
        unless delivery_id.match?(/\A[A-Za-z0-9-]{1,64}\z/)
          return render(json: { error: "#{DELIVERY_HEADER} is required" }, status: :bad_request)
        end

        payload = parse(body)
        return render(json: { error: "The delivery's body is not a JSON object" }, status: :bad_request) unless payload

        job_payload = GithubWebhookJob.payload_for(event, payload)
        recorded = GithubWebhookDelivery.record!(
          delivery_id: delivery_id, event: event,
          event_action: job_payload["action"].presence&.first(64),
          installation_id: job_payload.dig("installation", "id").presence&.to_i
        )
        return accepted("duplicate") unless recorded

        begin
          GithubWebhookJob.perform_later(event, job_payload)
        rescue StandardError
          # Not left recorded, so a redelivery of it is processed.
          GithubWebhookDelivery.forget!(delivery_id)
          raise
        end

        accepted("queued")
      end

      private

      # Constant time, whatever the header holds.
      def signed?(body, secret)
        given = request.headers[SIGNATURE_HEADER]
        return false unless given.is_a?(String) && given.start_with?("sha256=")

        expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
        ActiveSupport::SecurityUtils.secure_compare(expected, given)
      end

      def parse(body)
        body = Rack::Utils.parse_query(body)["payload"].to_s if request.media_type == "application/x-www-form-urlencoded"
        data = JSON.parse(body)
        data if data.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def accepted(status)
        render json: { status: status }, status: :accepted
      end
    end
  end
end
