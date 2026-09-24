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
      assert_match(/t\.string :external_tenant, \*\*exact_collation\n\s+t\.string :external_run_id, \*\*exact_collation\n\s+t\.string :external_report_digest/, content)
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

  test "an install whose tables predate published reports gets the release repair and the identity upgrade" do
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    EARLIER_MIGRATIONS.each_with_index do |name, index|
      File.write(File.join(destination_root, "db/migrate/2025010100000#{index}_#{name}.rb"), "")
    end

    run_generator [ "--skip-routes" ]

    assert_migration "db/migrate/ensure_agent_release_columns.rb"
    assert_migration "db/migrate/add_evaluation_report_identity.rb"
    assert_equal EARLIER_MIGRATIONS.size + 2, Dir[File.join(destination_root, "db/migrate/*.rb")].size
  end

  test "a traces-only install has no evaluation runs to alter" do
    run_generator [ "--skip-routes", "--traces-only" ]

    assert_no_migration "db/migrate/add_evaluation_report_identity.rb"
    assert_no_migration "db/migrate/ensure_agent_release_columns.rb"
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

  test "a fresh install emits the release repair after the dashboard tables" do
    run_generator [ "--skip-routes" ]

    assert_operator migration_version("ensure_agent_release_columns"), :>, migration_version("create_active_agent_dashboard_tables")
  end

  # An install generated fresh while add_agent_releases ran ahead of its
  # tables, here also under a custom prefix: the tables exist without any
  # release column. Built under a probe prefix so the dummy's own tables are
  # left alone.
  test "the release repair adds every missing release column, under the configured table prefix" do
    run_generator [ "--skip-routes" ]
    with_bare_tables("release_repair_probe_") do |connection, prefix|
      run_migration("ensure_agent_release_columns", :EnsureAgentReleaseColumns)
      run_migration("ensure_agent_release_columns", :EnsureAgentReleaseColumns)

      assert_release_columns(connection, prefix)
    end
  end

  test "add_agent_releases reads the configured table prefix" do
    run_generator [ "--skip-routes" ]
    with_bare_tables("release_prefix_probe_") do |connection, prefix|
      run_migration("add_agent_releases", :AddAgentReleases)

      assert_release_columns(connection, prefix)
    end
  end

  private

  def migration_version(name)
    File.basename(migration_file_name("db/migrate/#{name}.rb")).to_i
  end

  def run_migration(name, class_name)
    namespace = Module.new
    namespace.module_eval(File.read(migration_file_name("db/migrate/#{name}.rb")))
    ActiveRecord::Migration.suppress_messages { namespace.const_get(class_name).new.migrate(:up) }
  end

  BARE_TABLES = %w[agents agent_versions agent_runs evaluation_runs].freeze

  # Creates the four tables the release columns live on, with none of those
  # columns, under +prefix+, and makes it the configured prefix for the block.
  def with_bare_tables(prefix)
    connection = ActiveRecord::Base.connection
    BARE_TABLES.each do |name|
      connection.create_table("#{prefix}#{name}", force: true) { |t| t.bigint :agent_id }
    end
    ActionAgent.table_name_prefix = prefix
    yield connection, prefix
  ensure
    ActionAgent.table_name_prefix = "active_agent_"
    BARE_TABLES.each { |name| connection.drop_table("#{prefix}#{name}", if_exists: true) }
  end

  def assert_release_columns(connection, prefix)
    assert connection.column_exists?("#{prefix}agents", :release_digest)
    assert connection.column_exists?("#{prefix}agent_versions", :release_digest)
    assert connection.column_exists?("#{prefix}agent_versions", :revision)
    assert connection.index_exists?("#{prefix}agent_versions", [ :agent_id, :release_digest ])
    %w[agent_runs evaluation_runs].each do |name|
      assert connection.column_exists?("#{prefix}#{name}", :agent_version_id), "#{name} records the version it ran under"
      assert connection.index_exists?("#{prefix}#{name}", :agent_version_id)
    end
  end
end
