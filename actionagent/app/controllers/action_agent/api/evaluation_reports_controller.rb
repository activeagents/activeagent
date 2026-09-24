# frozen_string_literal: true

module ActionAgent
  module Api
    # Collector for evaluation reports an application ran itself and
    # published with ActiveAgent::Evals::Publisher:
    # POST <mount>/api/evaluation_reports (e.g. /activeagents/api/evaluation_reports).
    #
    # Authenticated exactly as trace ingest is (IngestAuthentication), and
    # stored by EvaluationReportImport. Responds:
    #
    #   201 — stored; the receipt the publisher checks
    #   200 — an identical retry; the receipt names the stored run
    #   409 — different content under a stored run_id, or an evaluation of
    #         that name the report does not belong to
    #   413 — a body over EvaluationReportImport::MAX_BYTES
    #   429 — denied by the host's quota checker (kind :evaluation_report),
    #         the owner holds the most observed agents it can, or more than
    #         RATE_LIMIT reports in a minute from one key
    #   400 — a body that is not JSON
    #   422 — JSON that is not a valid version-1 report
    #   401 — a missing or unknown key
    class EvaluationReportsController < ActionController::API
      include IngestAuthentication

      # Reports one key may deliver per minute.
      RATE_LIMIT = 30

      # The body is read once, by #create, with a size cap.
      wrap_parameters false

      before_action :enforce_report_quota!
      rate_limit to: RATE_LIMIT, within: 1.minute, by: -> { rate_limit_key },
        with: -> { render json: { error: "Too many evaluation reports; retry in a minute" }, status: :too_many_requests }

      # POST <mount>/api/evaluation_reports
      def create
        return report_too_large if request.content_length.to_i > EvaluationReportImport::MAX_BYTES

        body = request.body.read(EvaluationReportImport::MAX_BYTES + 1).to_s
        return report_too_large if body.bytesize > EvaluationReportImport::MAX_BYTES

        run, duplicate = EvaluationReportImport.call(account: @account, payload: JSON.parse(body))
        ActionAgent.record_usage(@account, :evaluation_report) unless duplicate

        render json: receipt(run, duplicate), status: duplicate ? :ok : :created
      rescue JSON::ParserError
        render json: { error: "Invalid JSON" }, status: :bad_request
      rescue EvaluationReportImport::Invalid, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue EvaluationReportImport::Conflict => e
        render json: { error: e.message }, status: :conflict
      rescue EvaluationReportImport::LimitExceeded => e
        render json: { error: e.message }, status: :too_many_requests
      end

      private

      # The host app's quota checker, asked with kind :evaluation_report.
      def enforce_report_quota!
        enforce_ingest_quota_for!(:evaluation_report, "Evaluation report limit reached")
      end

      # One bucket per key: the tenant's on a multi-tenant install, the
      # install's own on a single-tenant one.
      def rate_limit_key
        @account ? "account:#{@account.id}" : "install"
      end

      def receipt(run, duplicate)
        {
          id: run.id,
          evaluation_id: run.evaluation_id,
          run_id: run.external_run_id,
          status: run.status,
          duplicate: duplicate,
          url: run_url(run)
        }
      end

      # The dashboard page that shows the run, as a path on this host. A host
      # that routes to this controller from outside the engine's mount
      # overrides it.
      def run_url(run)
        "#{request.script_name}/evaluations/#{run.evaluation_id}/runs/#{run.id}"
      end

      # 413 by number: Rack named it :payload_too_large before 3.1 and
      # :content_too_large since, and the engine supports both.
      def report_too_large
        render json: { error: "Report exceeds #{EvaluationReportImport::MAX_BYTES / 1.megabyte} MiB" }, status: 413
      end
    end
  end
end
