# frozen_string_literal: true

module ActiveAgent
  # Processes telemetry traces received from ActiveAgent clients.
  #
  # This job handles the asynchronous processing of trace data to avoid
  # blocking the ingestion endpoint. It:
  # - Creates TelemetryTrace records for each trace
  # - Updates aggregate statistics
  # - Handles any errors gracefully
  #
  # @example Local mode
  #   ActiveAgent::ProcessTelemetryTracesJob.perform_later(
  #     traces: [...],
  #     sdk_info: { name: "activeagent", version: "0.5.0" },
  #     received_at: "2024-01-15T10:30:00Z"
  #   )
  #
  # @example Multi-tenant mode
  #   ActiveAgent::ProcessTelemetryTracesJob.perform_later(
  #     account_id: 1,
  #     traces: [...],
  #     sdk_info: { name: "activeagent", version: "0.5.0" },
  #     received_at: "2024-01-15T10:30:00Z"
  #   )
  #
  class ProcessTelemetryTracesJob < ::ActiveJob::Base
    queue_as :default

    # Maximum traces to process in a single job to avoid memory issues
    MAX_TRACES_PER_JOB = 100

    def perform(account_id: nil, traces:, sdk_info:, received_at:)
      account = resolve_account(account_id)

      # In multi-tenant mode, require an account
      if ActiveAgent::Dashboard.multi_tenant? && account.nil?
        Rails.logger.warn("[ProcessTelemetryTracesJob] Skipping traces - no valid account")
        return
      end

      traces = traces.take(MAX_TRACES_PER_JOB)

      traces.each do |trace|
        process_trace(trace, sdk_info, account)
      rescue StandardError => e
        Rails.logger.error(
          "[ProcessTelemetryTracesJob] Failed to process trace #{trace['trace_id']}: " \
          "#{e.class} - #{e.message}"
        )
      end
    end

    private

    def resolve_account(account_id)
      return nil unless ActiveAgent::Dashboard.multi_tenant?
      return nil unless account_id

      account_class = ActiveAgent::Dashboard.account_class.constantize
      account_class.find_by(id: account_id)
    end

    def process_trace(trace, sdk_info, account)
      model = ActiveAgent::Dashboard.trace_model

      # Build uniqueness scope
      scope = model.where(trace_id: trace["trace_id"])
      scope = scope.where(account: account) if ActiveAgent::Dashboard.multi_tenant? && account

      # Skip if trace already exists (idempotency)
      return if scope.exists?

      model.create_from_payload(trace, sdk_info, account: account)
    end
  end
end
