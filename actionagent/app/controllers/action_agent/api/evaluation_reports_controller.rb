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
    #   200 — an identical retry; the receipt names the stored run. Never
    #         refused by the quota or the rate limit.
    #   409 — this run_id already holds a different report
    #   422 — not a valid version-1 report, or an evaluation name the agent
    #         already holds for another suite or scope
    #   403 — storing it needs an operator first: a cap on observed agents,
    #         evaluations or scenarios, or no owner for the tenant
    #   429 — a new report over the host's quota (kind :evaluation_report) or
    #         over RATE_LIMIT new reports a minute from one key
    #   413 — a body over EvaluationReportImport::MAX_BYTES
    #   415 — a body that is not declared application/json
    #   400 — a body that is not JSON
    #   401 — a missing or unknown key
    #   501 — an install with no evaluation tables, or not yet migrated
    #   503 — another import for the same agent held the lock too long
    #
    # GET <mount>/api/evaluation_reports/:run_id returns a stored run as the
    # same version-1 envelope (EvaluationReportExport), so it can be posted to
    # another install, or back to this one as an identical retry. Responds
    # 200 with the envelope (or, with `format=html` or `format=md`, the
    # report page or its Markdown), 404 for a run_id the key's tenant holds
    # no run under, 422 for an envelope of a run that is not complete or an
    # unknown format, and 401 and 501 as above.
    class EvaluationReportsController < ActionController::API
      include IngestAuthentication

      # What #show serves for each `format`.
      EXPORT_FORMATS = { "json" => "application/json", "html" => "text/html", "md" => "text/markdown" }.freeze

      # New reports one key may store per minute.
      RATE_LIMIT = 30

      wrap_parameters false

      before_action :require_json!, only: :create
      before_action :require_report_store!

      # POST <mount>/api/evaluation_reports
      def create
        # The header, not request.content_length, which reads a chunked body
        # in full to measure it.
        return report_too_large if request.get_header("CONTENT_LENGTH").to_i > EvaluationReportImport::MAX_BYTES

        body = request.body.read(EvaluationReportImport::MAX_BYTES + 1).to_s
        return report_too_large if body.bytesize > EvaluationReportImport::MAX_BYTES

        run, duplicate = EvaluationReportImport.call(account: @account, payload: JSON.parse(body), admit: -> { admission_denial })
        ActionAgent.record_usage(@account, :evaluation_report) unless duplicate

        render json: receipt(run, duplicate), status: duplicate ? :ok : :created
      rescue JSON::ParserError
        render json: { error: "Invalid JSON" }, status: :bad_request
      rescue EvaluationReportImport::Invalid, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue EvaluationReportImport::Conflict => e
        render json: { error: e.message }, status: :conflict
      rescue EvaluationReportImport::Refused => e
        render json: { error: e.message }, status: :forbidden
      rescue EvaluationReportImport::Denied => e
        render json: e.denial, status: :too_many_requests
      rescue EvaluationReportImport::Busy => e
        response.headers["Retry-After"] = "5"
        render json: { error: e.message }, status: :service_unavailable
      end

      # GET <mount>/api/evaluation_reports/:run_id
      #
      # :run_id is an imported run's run_id as it was published, or the
      # "dashboard-run-<id>-<stamp>" a run the dashboard executed exports
      # under (EvaluationReportExport.run_id_for). Found within the key's
      # tenant exactly as #create finds a stored run. `format=html` returns
      # the run's self-contained report page (text/html) as run_report renders
      # it, and `format=md` its Markdown (text/markdown), instead of the
      # envelope; any other format is a 422. `download=1` sends any of them
      # as an attachment named like the dashboard's downloads.
      def show
        run = EvaluationReportExport.find(params[:run_id], account: @account)
        return render json: { error: "No evaluation report with that run_id" }, status: :not_found unless run

        format = params[:format].presence || "json"
        unless EXPORT_FORMATS.key?(format)
          return render json: { error: "format is one of #{EXPORT_FORMATS.keys.join(', ')}" }, status: :unprocessable_entity
        end

        export = EvaluationReportExport.new(run)
        body =
          case format
          when "json" then export.to_json
          when "md" then export.markdown
          # The page run_report serves, its fix actions linking into this
          # dashboard by absolute path; no theme, so it follows the viewer.
          when "html" then run.to_report(links: run.report_links(mount: request.script_name)).to_html
          end
        send_data body, type: EXPORT_FORMATS.fetch(format), disposition: download? ? "attachment" : "inline",
                        filename: export.filename(format)
      rescue EvaluationReportExport::NotExportable => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # Rails reads and parses a JSON body into params before any callback
      # runs, for the request log among others. With none to parse, the body
      # is read only by #create, and only up to the size limit.
      def process_action(*)
        request.request_parameters = {}
        super
      end

      # A cross-site page can send a text/plain or form POST without a CORS
      # preflight; it cannot send application/json.
      def require_json!
        return if request.media_type == "application/json"

        render json: { error: "Content-Type must be application/json" }, status: :unsupported_media_type
      end

      def download?
        ActiveModel::Type::Boolean.new.cast(params[:download]) == true
      end

      def require_report_store!
        reason = EvaluationReportImport.unavailable_reason
        render json: { error: reason }, status: :not_implemented if reason
      end

      # What refuses a report that would be stored, or nil: the rate limit,
      # then the host app's quota checker, asked with kind :evaluation_report.
      # Never asked for an identical retry.
      def admission_denial
        return { error: "Too many evaluation reports; retry in a minute" } if rate_limited?

        denial = ActionAgent.quota_denial(@account, :evaluation_report)
        quota_denial_body(denial, "Evaluation report limit reached") if denial.present?
      end

      # Counts a new report against its key's bucket, in the store Rails'
      # own rate_limit uses. One bucket per key: the tenant's on a
      # multi-tenant install, the install's own on a single-tenant one.
      def rate_limited?
        bucket = @account ? "account:#{@account.id}" : "install"
        count = self.class.cache_store.increment("rate-limit:#{controller_path}:#{bucket}", 1, expires_in: 1.minute)
        count.present? && count > RATE_LIMIT
      end

      def receipt(run, duplicate)
        {
          id: run.id,
          evaluation_id: run.evaluation_id,
          run_id: EvaluationReportExport.run_id_for(run),
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
