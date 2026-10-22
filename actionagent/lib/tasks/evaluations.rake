# frozen_string_literal: true

# Evaluation run reports from the command line: a run out as the version-1
# envelope the evaluation report collector takes (or as its HTML report page,
# or as GitHub-flavored Markdown for a pull request), and an envelope in
# through the collector's own import. On a multi-tenant install name the
# tenant with ACCOUNT_ID=<id>.
#
#   bin/rails action_agent:evaluations:export RUN=dashboard-run-12-20261021093000 FILE=tmp/run.json
#   bin/rails action_agent:evaluations:export EVALUATION=3 RUN=12 FORMAT=html FILE=tmp/run.html
#   bin/rails action_agent:evaluations:export EVALUATION=3 RUN=12 FORMAT=md > tmp/run.md
#   bin/rails action_agent:evaluations:import FILE=tmp/run.json
namespace :action_agent do
  namespace :evaluations do
    desc "Write a run's report (RUN=run_id, or EVALUATION=id RUN=id; FORMAT=json|html|md; FILE=path, standard output without FILE)"
    task export: :environment do
      run = action_agent_evaluation_run!
      export = ActionAgent::EvaluationReportExport.new(run)
      format = ENV.fetch("FORMAT", "json").downcase
      body =
        case format
        when "json" then export.to_json
        when "html" then run.to_report.to_html
        when "md", "markdown" then export.markdown
        else abort "FORMAT is json, html or md"
        end

      if ENV["FILE"].present?
        File.write(ENV["FILE"], body)
        puts "Wrote run #{export.run_id} of #{run.evaluation.name} (#{format}) to #{ENV['FILE']}"
      else
        puts body
      end
    rescue ActionAgent::EvaluationReportExport::NotExportable => e
      abort "Export refused: #{e.message}"
    end

    desc "Store a version-1 evaluation report envelope (FILE=path [ACCOUNT_ID=id]); importing it again changes nothing"
    task import: :environment do
      path = ENV.fetch("FILE") { abort "Name the file: FILE=tmp/run.json" }
      abort "No file at #{path}" unless File.file?(path)
      abort "Unavailable: #{ActionAgent::EvaluationReportImport.unavailable_reason}" if ActionAgent::EvaluationReportImport.unavailable_reason

      account = action_agent_evaluation_account
      run, duplicate = ActionAgent::EvaluationReportImport.call(account: account, payload: JSON.parse(File.read(path)))
      ActionAgent.record_usage(account, :evaluation_report) unless duplicate
      puts "#{duplicate ? 'Already stored (identical retry)' : 'Stored'}: run #{ActionAgent::EvaluationReportExport.run_id_for(run)} " \
           "as run ##{run.id} of evaluation ##{run.evaluation_id} (#{run.evaluation.name}), #{run.status}"
    rescue JSON::ParserError
      abort "Import refused: #{path} is not JSON"
    rescue ActionAgent::EvaluationReportImport::Error, ActiveRecord::RecordInvalid => e
      abort "Import refused: #{e.message}"
    end
  end
end

# The tenant, from ACCOUNT_ID (ACCOUNT also works); nil on a single-tenant
# install.
def action_agent_evaluation_account
  id = ENV["ACCOUNT_ID"].presence || ENV["ACCOUNT"].presence
  return nil unless id

  abort "ACCOUNT_ID names a tenant, which only a multi-tenant install has" unless ActionAgent.multi_tenant?
  ActionAgent.account_class.to_s.constantize.find_by(id: id) || abort("No account #{id}")
end

# The run RUN names: with EVALUATION, a run id of that evaluation; without,
# a run_id as the export endpoint takes it, within the tenant.
def action_agent_evaluation_run!
  run_id = ENV.fetch("RUN") { abort "Name the run: RUN=<run_id>, or EVALUATION=<id> RUN=<id>" }
  if ENV["EVALUATION"].present?
    evaluation = ActionAgent::Evaluation.find_by(id: ENV["EVALUATION"]) || abort("No evaluation #{ENV['EVALUATION']}")
    evaluation.evaluation_runs.find_by(id: run_id) || abort("No run #{run_id} in evaluation #{evaluation.id}")
  else
    ActionAgent::EvaluationReportExport.find(run_id, account: action_agent_evaluation_account) ||
      abort("No run with run_id #{run_id.inspect}#{' for that account' if ENV['ACCOUNT_ID'].present? || ENV['ACCOUNT'].present?}")
  end
end
