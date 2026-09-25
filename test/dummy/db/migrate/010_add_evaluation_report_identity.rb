# frozen_string_literal: true

# Published evaluation reports: an application that runs its agents itself
# can evaluate them in-process and POST the finished report to
# <mount>/api/evaluation_reports (ActionAgent::EvaluationReportImport), which
# stores it as an evaluation run. The run is identified by the run_id the
# application minted, within the tenant whose key published it, and carries
# the digest of the report, so an identical retry resolves to the same run and
# different content under the same run_id is refused.
#
# The tenant is its id, or "" on a single-tenant install, because a unique
# index never treats two NULLs as equal. Both are compared exactly, which on
# MySQL takes a binary collation. All three columns are NULL for a run the
# dashboard executed. Emitted for an install whose dashboard tables predate
# published reports; the create-table migration carries the same columns for
# a fresh install. Each step is guarded, so the migration is safe to re-run.
class AddEvaluationReportIdentity < ActiveRecord::Migration[7.2]
  IDENTITY = [ :external_tenant, :external_run_id ].freeze

  def up
    return unless table_exists?(table)

    IDENTITY.each do |column|
      add_column table, column, :string, **exact_collation unless column_exists?(table, column)
    end
    add_column table, :external_report_digest, :string unless column_exists?(table, :external_report_digest)
    add_index table, IDENTITY, unique: true, name: index_name unless index_exists?(table, IDENTITY, name: index_name)
  end

  def down
    return unless table_exists?(table)

    remove_index table, name: index_name if index_exists?(table, IDENTITY, name: index_name)
    %i[external_tenant external_run_id external_report_digest].each do |column|
      remove_column table, column if column_exists?(table, column)
    end
  end

  private

  def table
    "#{ActionAgent.table_name_prefix}evaluation_runs"
  end

  def index_name
    "index_#{ActionAgent.table_name_prefix}evaluation_runs_on_external_identity"
  end

  # MySQL's default collation ignores case and accents, so "nightly-a" and
  # "Nightly-A" would be one run_id there and two everywhere else.
  def exact_collation
    connection.adapter_name.to_s.downcase.match?(/mysql|trilogy/) ? { collation: "utf8mb4_bin" } : {}
  end
end
