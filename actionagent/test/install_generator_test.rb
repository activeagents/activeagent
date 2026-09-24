# frozen_string_literal: true

require "test_helper"
require "generators/action_agent/install_generator"

# The migrations action_agent:install emits for columns added after the
# dashboard tables shipped: carried by the create-table migration on a fresh
# install, and emitted as a guarded upgrade for an install whose tables
# predate them.
class ActionAgentInstallGeneratorTest < Rails::Generators::TestCase
  tests ActionAgent::InstallGenerator
  destination Rails.root.join("tmp/generators/action_agent_install")
  setup :prepare_destination

  EARLIER_MIGRATIONS = %w[
    create_active_agent_telemetry_traces
    add_agent_id_to_active_agent_telemetry_traces
    add_agent_releases
    create_active_agent_dashboard_tables
    create_active_agent_evaluation_scenarios
  ].freeze

  test "a fresh install creates evaluation runs with the report identity and emits the upgrade after them" do
    run_generator [ "--skip-routes" ]

    assert_migration "db/migrate/create_active_agent_dashboard_tables.rb" do |content|
      assert_match(/t\.string :external_tenant\n\s+t\.string :external_run_id\n\s+t\.string :external_report_digest/, content)
      assert_match(/t\.index \[ :external_tenant, :external_run_id \], unique: true/, content)
    end
    assert_migration "db/migrate/add_evaluation_report_identity.rb"
    assert_operator migration_version("add_evaluation_report_identity"), :>, migration_version("create_active_agent_dashboard_tables"),
      "the upgrade must run after the table it alters exists"
  end

  # add_agent_releases is emitted before the dashboard tables, so on a fresh
  # install it finds none of them and the create-table migration has to carry
  # what it would have added.
  test "a fresh install creates the release columns with the dashboard tables" do
    run_generator [ "--skip-routes" ]

    assert_migration "db/migrate/create_active_agent_dashboard_tables.rb" do |content|
      tables = content.split(/^\s+create_table /).to_h { |block| [ block[/\A"\#\{prefix\}(\w+)"/, 1], block ] }
      assert_match(/t\.string :release_digest/, tables["agents"])
      assert_match(/t\.string :release_digest\n\s+t\.string :revision/, tables["agent_versions"])
      assert_match(/t\.index \[ :agent_id, :release_digest \]/, tables["agent_versions"])
      %w[agent_runs evaluation_runs].each do |table|
        assert_match(/t\.bigint :agent_version_id/, tables[table], "#{table} records the version it ran under")
        assert_match(/t\.index :agent_version_id/, tables[table])
      end
    end
  end

  test "an install whose tables predate published reports gets only the upgrade" do
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    EARLIER_MIGRATIONS.each_with_index do |name, index|
      File.write(File.join(destination_root, "db/migrate/2025010100000#{index}_#{name}.rb"), "")
    end

    run_generator [ "--skip-routes" ]

    assert_migration "db/migrate/add_evaluation_report_identity.rb"
    assert_equal EARLIER_MIGRATIONS.size + 1, Dir[File.join(destination_root, "db/migrate/*.rb")].size
  end

  test "a traces-only install has no evaluation runs to alter" do
    run_generator [ "--skip-routes", "--traces-only" ]

    assert_no_migration "db/migrate/add_evaluation_report_identity.rb"
  end

  test "the upgrade is a no-op against a table that already has the identity" do
    run_generator [ "--skip-routes" ]
    namespace = Module.new
    namespace.module_eval(File.read(migration_file_name("db/migrate/add_evaluation_report_identity.rb")))

    ActiveRecord::Migration.suppress_messages { namespace::AddEvaluationReportIdentity.new.migrate(:up) }

    connection = ActiveRecord::Base.connection
    table = ActionAgent::EvaluationRun.table_name
    assert connection.index_exists?(table, [ :external_tenant, :external_run_id ], unique: true)
    assert_equal %w[external_report_digest external_run_id external_tenant],
      connection.columns(table).map(&:name).grep(/\Aexternal_/).sort
  end

  private

  def migration_version(name)
    File.basename(migration_file_name("db/migrate/#{name}.rb")).to_i
  end
end
