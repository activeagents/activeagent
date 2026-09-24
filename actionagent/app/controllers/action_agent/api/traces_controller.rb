# frozen_string_literal: true

module ActionAgent
  module Api
    # Telemetry ingestion endpoint.
    #
    # Receives traces from ActiveAgent::Telemetry::Reporter and stores them
    # for analysis and visualization in the dashboard.
    #
    # Supports two modes:
    # - Local mode: synchronous processing; unauthenticated unless
    #   ActionAgent.ingest_api_key is set (set it whenever the
    #   mount is reachable beyond your own machine)
    # - Multi-tenant mode: per-account Bearer token auth, async processing
    #   via job
    #
    # @example Local mode request
    #   POST <mount>/api/traces  (e.g. /activeagents/api/traces)
    #   Content-Type: application/json
    #
    #   {
    #     "traces": [...],
    #     "sdk": { "name": "activeagent", "version": "0.5.0" }
    #   }
    #
    # @example Multi-tenant mode request
    #   POST <mount>/api/traces  (e.g. /activeagents/api/traces)
    #   Authorization: Bearer <api_key>
    #   Content-Type: application/json
    #
    #   {
    #     "traces": [...],
    #     "sdk": { "name": "activeagent", "version": "0.5.0" }
    #   }
    #
    class TracesController < ActionController::API
      include IngestAuthentication

      before_action :enforce_ingest_quota!

      # POST <mount>/api/traces  (e.g. /activeagents/api/traces)
      #
      # Every trace in the request is accepted. The reporter flushes its
      # whole buffer once it reaches batch_size (which is configurable), so
      # a single POST legitimately carries more than a hundred traces; this
      # used to keep the first hundred and answer 202 for the rest, which
      # were silently gone. ProcessTelemetryTracesJob bounds its own work by
      # slicing and re-enqueueing the remainder.
      def create
        traces = Array(params[:traces])
        sdk_info = params[:sdk] || {}

        return head :accepted if traces.empty?

        if ActionAgent.multi_tenant?
          # Multi-tenant mode: process in background
          ActionAgent::ProcessTelemetryTracesJob.perform_later(
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
        Rails.logger.error("[ActionAgent] Trace ingestion error: #{e.message}")
        render json: { error: "Internal server error" }, status: :internal_server_error
      end

      private

      # The host app's quota checker, asked with kind :trace_ingest.
      def enforce_ingest_quota!
        enforce_ingest_quota_for!(:trace_ingest, "Trace ingest limit reached")
      end

      # Counts the request against the tenant, when its account model
      # defines the hook.
      def record_ingest_request
        @account.increment_telemetry_usage! if @account.respond_to?(:increment_telemetry_usage!)
      end

      # Process traces synchronously for local development.
      def process_traces_synchronously(traces, sdk_info)
        model = ActionAgent.trace_model

        traces.each do |trace|
          # Skip if trace already exists (idempotency)
          next if model.exists?(trace_id: trace["trace_id"])

          model.create_from_payload(trace, sdk_info)
        rescue StandardError => e
          Rails.logger.error(
            "[ActionAgent] Failed to process trace #{trace['trace_id']}: " \
            "#{e.class} - #{e.message}"
          )
        end
      end
    end
  end
end
