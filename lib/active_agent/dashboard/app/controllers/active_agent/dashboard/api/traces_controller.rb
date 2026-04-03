# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    module Api
      # Telemetry ingestion endpoint.
      #
      # Receives traces from ActiveAgent::Telemetry::Reporter and stores them
      # for analysis and visualization in the dashboard.
      #
      # Supports two modes:
      # - Local mode: No authentication, synchronous processing
      # - Multi-tenant mode: Bearer token auth, async processing via job
      #
      # @example Local mode request
      #   POST /active_agent/api/traces
      #   Content-Type: application/json
      #
      #   {
      #     "traces": [...],
      #     "sdk": { "name": "activeagent", "version": "0.5.0" }
      #   }
      #
      # @example Multi-tenant mode request
      #   POST /active_agent/api/traces
      #   Authorization: Bearer <api_key>
      #   Content-Type: application/json
      #
      #   {
      #     "traces": [...],
      #     "sdk": { "name": "activeagent", "version": "0.5.0" }
      #   }
      #
      class TracesController < ActionController::API
        before_action :authenticate_api_key!, if: -> { ActiveAgent::Dashboard.multi_tenant? }

        # POST /active_agent/api/traces
        def create
          traces = params[:traces] || []
          sdk_info = params[:sdk] || {}

          return head :accepted if traces.empty?

          if ActiveAgent::Dashboard.multi_tenant?
            # Multi-tenant mode: process in background
            ActiveAgent::ProcessTelemetryTracesJob.perform_later(
              account_id: @account&.id,
              traces: traces.as_json,
              sdk_info: sdk_info.as_json,
              received_at: Time.current.iso8601(6)
            )
          else
            # Local mode: process synchronously
            process_traces_synchronously(traces, sdk_info)
          end

          head :accepted
        rescue ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :bad_request
        rescue StandardError => e
          Rails.logger.error("[ActiveAgent::Dashboard] Trace ingestion error: #{e.message}")
          render json: { error: "Internal server error" }, status: :internal_server_error
        end

        private

        # Authenticates the request using Bearer token from Authorization header.
        # Only used in multi-tenant mode.
        def authenticate_api_key!
          token = extract_bearer_token

          if token.blank?
            render json: { error: "Missing Authorization header" }, status: :unauthorized
            return
          end

          account_class = ActiveAgent::Dashboard.account_class.constantize
          @account = account_class.find_by(telemetry_api_key: token)

          if @account.nil?
            render json: { error: "Invalid API key" }, status: :unauthorized
            return
          end

          # Track usage for rate limiting (if the account responds to it)
          @account.increment_telemetry_usage! if @account.respond_to?(:increment_telemetry_usage!)
        end

        # Extracts Bearer token from Authorization header.
        def extract_bearer_token
          auth_header = request.headers["Authorization"]
          return nil if auth_header.blank?

          match = auth_header.match(/^Bearer\s+(.+)$/i)
          match[1] if match
        end

        # Process traces synchronously for local development.
        def process_traces_synchronously(traces, sdk_info)
          model = ActiveAgent::Dashboard.trace_model

          traces.each do |trace|
            # Skip if trace already exists (idempotency)
            next if model.exists?(trace_id: trace["trace_id"])

            model.create_from_payload(trace, sdk_info)
          rescue StandardError => e
            Rails.logger.error(
              "[ActiveAgent::Dashboard] Failed to process trace #{trace['trace_id']}: " \
              "#{e.class} - #{e.message}"
            )
          end
        end
      end
    end
  end
end
