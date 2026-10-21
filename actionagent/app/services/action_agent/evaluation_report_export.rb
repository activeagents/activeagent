# frozen_string_literal: true

require "digest"
require "json"

module ActionAgent
  # A complete scenario run as the version-1 envelope
  # ActiveAgent::Evals::Publisher sends, built with Publisher.envelope so the
  # two share one shape. What the export endpoints and
  # `action_agent:evaluations:export` serve: POSTed to another install's
  # <mount>/api/evaluation_reports it is stored there, and POSTed back to this
  # one it is an identical retry (EvaluationReportImport accepts a run's own
  # export as identical to the run).
  #
  # The identities come from the run:
  #   run_id     — an imported run's own run_id, exactly as published. A run
  #                the dashboard executed has none, so it is given
  #                "dashboard-run-<id>-<created_at as YYYYMMDDhhmmss UTC>":
  #                stable for the run, and unlikely to meet another
  #                install's run of the same id where both are imported.
  #   source     — an imported run's source; for a dashboard run the agent's
  #                service, else the host application's name ("support-hub").
  #   agent_name — the agent's class name, else its name.
  #   suite      — an imported run's suite; for a dashboard run the
  #                evaluation's name.
  #
  # The report is EvaluationRun#to_report(estimate: false): what the run
  # recorded, with no cost estimated, so the same run always exports the
  # same envelope. Its metadata leaves out the run's database id.
  class EvaluationReportExport
    # The run cannot be exported: it is not complete, or its evaluation is
    # not a scenario suite.
    class NotExportable < StandardError; end
    # #markdown was asked for a part the report does not have.
    class UnknownPart < ArgumentError; end

    DASHBOARD_RUN_ID = /\Adashboard-run-(\d+)-(\d{14})\z/
    STAMP_FORMAT = "%Y%m%d%H%M%S"

    # The run_id a run exports under.
    def self.run_id_for(run)
      run.external_run_id.presence || "dashboard-run-#{run.id}-#{run.created_at.utc.strftime(STAMP_FORMAT)}"
    end

    # The run +run_id+ names for the tenant +account+ (nil on a single-tenant
    # install), or nil. An imported run is found by the run_id it was
    # published under, within the tenant that published it, as
    # EvaluationReportImport finds it. A dashboard run is found by its
    # exported run_id, when its agent is one of the tenant's
    # (ActionAgent.agents_for); a single-tenant key reaches every agent, as
    # the import's does.
    def self.find(run_id, account: nil)
      return nil unless run_id.is_a?(String) && run_id.present?

      imported = EvaluationRun.find_by(external_tenant: account ? account.id.to_s : "", external_run_id: run_id)
      return imported if imported

      match = DASHBOARD_RUN_ID.match(run_id)
      return nil unless match

      run = EvaluationRun.where(external_run_id: nil).find_by(id: match[1].to_i)
      return nil unless run && run_id_for(run) == run_id
      return run if account.nil? && !ActionAgent.multi_tenant?

      run if account && ActionAgent.agents_for(account).exists?(id: run.evaluation.agent_id)
    end

    attr_reader :run

    def initialize(run)
      @run = run
    end

    def run_id
      self.class.run_id_for(run)
    end

    # Raises NotExportable for a run that is not a complete scenario run:
    # what every format of the export, not only the envelope, needs.
    def exportable!
      raise NotExportable, "Only a complete run can be exported" unless run.complete?
      raise NotExportable, "Only a scenario suite's run can be exported" unless evaluation.scenario_suite?
    end

    # Raises NotExportable for a run that is not a complete scenario run.
    def envelope
      @envelope ||= begin
        exportable!

        built = ActiveAgent::Evals::Publisher.envelope(
          report: run.to_report(links: {}, estimate: false),
          run_id: run_id, source: source, agent_name: agent_name, suite: suite
        )
        # As JSON reads it back, so the digest is the one a POST of it gets.
        JSON.parse(JSON.generate(built)).tap do |parsed|
          # The run's database id means nothing on another install; run_id
          # is the run's identity there.
          metadata = parsed["report"]["metadata"]
          metadata.delete("run") if metadata.is_a?(Hash) && metadata["run"] == run.id
        end
      end
    end

    def to_json(*)
      JSON.pretty_generate(envelope)
    end

    # Parts of the report #markdown serves on its own.
    MARKDOWN_PARTS = %w[report verdict fix_items scenario].freeze

    # The run's report as GitHub-flavored Markdown
    # (ActiveAgent::Evals::ReportMarkdown), with the costs the dashboard shows:
    # the whole report, or one +part+ — "verdict" (with the model
    # comparison), "fix_items" (for +model+, a model label, when given) or
    # "scenario" (the one +scenario+ names). Raises UnknownPart for an
    # unknown part and ActiveRecord::RecordNotFound for a scenario the run
    # has no result for.
    def markdown(part: nil, model: nil, scenario: nil)
      report = run.to_report(links: {})
      case part.presence || "report"
      when "report" then report.to_markdown
      when "verdict" then report.verdict_markdown
      when "fix_items" then report.fix_items_markdown(model: model.presence)
      when "scenario" then scenario_markdown(report, scenario.to_s)
      else raise UnknownPart, "part is one of #{MARKDOWN_PARTS.join(', ')}"
      end
    end

    # The digest EvaluationReportImport records for this envelope.
    def digest
      EvaluationReportImport.digest(envelope)
    end

    # "orders-eu-run-3.json" for the third run of "orders (eu)"; a part of
    # the Markdown report adds its name: "orders-eu-run-3-fix-items.md".
    def filename(extension, number: EvaluationSerializer.run_number(evaluation, run), part: nil)
      base = "#{evaluation.name.to_s.parameterize.presence || "evaluation-#{evaluation.id}"}-run-#{number}"
      base += "-#{part.to_s.dasherize.parameterize}" if part.present? && part.to_s != "report"
      "#{base}.#{extension}"
    end

    private

    def scenario_markdown(report, key)
      raise ActiveRecord::RecordNotFound, "The run has no result for scenario #{key}" unless report.results.any? { |result| result.scenario.key == key }

      report.scenario_markdown(key)
    end

    def evaluation
      run.evaluation
    end

    def agent
      evaluation.agent
    end

    def external
      value = evaluation.config.to_h["external"]
      run.imported? && value.is_a?(Hash) ? value : {}
    end

    def source
      (external["source"].presence || agent.service_name.presence || Rails.application.class.module_parent_name.underscore.dasherize).first(200)
    end

    def agent_name
      (agent.agent_class_name.presence || agent.name).to_s.first(100)
    end

    def suite
      (external["suite"].presence || evaluation.name).to_s.first(200)
    end
  end
end
