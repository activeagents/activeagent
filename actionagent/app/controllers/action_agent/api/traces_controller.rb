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
      before_action :authenticate_api_key!, if: -> { ActionAgent.multi_tenant? }
      before_action :authenticate_ingest_key!, unless: -> { ActionAgent.multi_tenant? }
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

      # Authenticates the request using Bearer token from Authorization header.
      # Only used in multi-tenant mode.
      def authenticate_api_key!
        token = extract_bearer_token

        if token.blank?
          render json: { error: "Missing Authorization header" }, status: :unauthorized
          return
        end

        account_class = ActionAgent.account_class.constantize
        @account = account_class.find_by(telemetry_api_key: token)

        if @account.nil?
          render json: { error: "Invalid API key" }, status: :unauthorized
          return
        end

        # Track usage for rate limiting (if the account responds to it)
        @account.increment_telemetry_usage! if @account.respond_to?(:increment_telemetry_usage!)
      end

      # Requires the configured single-tenant ingest key when one is set.
      # The telemetry reporter and ruby_llm_telemetry both send their
      # api_key as a Bearer header, so remote apps work unchanged.
      def authenticate_ingest_key!
        expected = ActionAgent.ingest_api_key
        return if expected.blank?

        token = extract_bearer_token
        return if token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)

        render json: { error: "Invalid API key" }, status: :unauthorized
      end

      # The host app's quota checker, asked with kind :trace_ingest — the
      # counterpart to Api::BaseController#enforce_quota!, which asks with
      # :execution. Denials are 429 here rather than 402: a reporter that is
      # over its ingest allowance should back off, not upgrade mid-flush.
      # Same body shape, so a checker's message or Hash payload reads the
      # same on both.
      def enforce_ingest_quota!
        denial = ActionAgent.quota_denial(@account, :trace_ingest)
        return if denial.blank?

        body = { error: "Trace ingest limit reached" }
        body = denial.is_a?(Hash) ? body.merge(denial) : body.merge(message: denial)

        render json: body, status: :too_many_requests
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
