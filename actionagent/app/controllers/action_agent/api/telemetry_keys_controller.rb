# frozen_string_literal: true

module ActionAgent
  module Api
    # The key the owner's applications send traces with, for the Organization
    # view to show and copy. The dashboard page does not carry it
    # (DashboardController).
    class TelemetryKeysController < BaseController
      before_action :require_owner!

      # GET /api/telemetry_key
      #
      # `telemetry_api_key` is the owner's `telemetry_api_key`, or null when
      # the owner has none.
      def show
        response.headers["Cache-Control"] = "no-store"
        render json: { telemetry_api_key: current_owner.try(:telemetry_api_key) }
      end
    end
  end
end
