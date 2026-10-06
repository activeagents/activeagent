# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/action_agent/install_generator"

# The migrations action_agent:install emits. A fresh install gets every
# migration the engine's models need, with columns added after the dashboard
# tables shipped carried by the create-table migration. Re-running it on an
# install from before a table or column shipped adds just what is missing,
# as a guarded upgrade for a column.
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

  # The numbered migration templates the engine ships, as
  # [template path, migration name] pairs.
  NUMBERED = ActionAgent::InstallGenerator.numbered_migrations.freeze

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
    assert_migration "db/migrate/add_provider_key_api_key.rb"
    assert_migration "db/migrate/create_active_agent_github_connections.rb"
    assert_migration "db/migrate/create_active_agent_code_sessions.rb"
    assert_migration "db/migrate/add_code_session_runner.rb"
    assert_equal EARLIER_MIGRATIONS.size + 6 + NUMBERED.size, Dir[File.join(destination_root, "db/migrate/*.rb")].size
  end

  test "a fresh install emits the Claude Code sessions table with the dashboard's" do
    run_generator [ "--skip-routes" ]

    assert_migration "db/migrate/create_active_agent_dashboard_tables.rb"
    assert_migration "db/migrate/create_active_agent_github_connections.rb"
    assert_migration "db/migrate/create_active_agent_code_sessions.rb" do |migration|
      assert_match(/class CreateActiveAgentCodeSessions < ActiveRecord::Migration\[\d+\.\d+\]/, migration)
      assert_match(/create_table "\#{prefix}code_sessions"/, migration)
      assert_match(/t\.bigint :sandbox_session_id, null: false/, migration)
    end
  end

  test "an install that predates code sessions gets the table and runner upgrade" do
    migrate = File.join(destination_root, "db/migrate")
    FileUtils.mkdir_p(migrate)
    installed = EARLIER_MIGRATIONS + %w[
      ensure_agent_release_columns add_evaluation_report_identity add_provider_key_api_key
      create_active_agent_github_connections
    ]
    installed.each_with_index do |name, index|
      File.write(File.join(migrate, format("202501010000%02d_%s.rb", index, name)), "# already installed\n")
    end

    run_generator [ "--skip-routes" ]

    assert_migration "db/migrate/create_active_agent_code_sessions.rb"
    emitted = Dir.children(migrate).reject { |file| file.start_with?("202501010000") }
    assert_migration "db/migrate/add_code_session_runner.rb"
    assert_equal 2 + NUMBERED.size, emitted.size, "only the missing migrations are emitted: #{emitted.inspect}"
    assert_equal 1, Dir.glob(File.join(migrate, "*_create_active_agent_github_connections.rb")).size
  end

  test "an install that has the Claude Code sessions table is not given a second one" do
    run_generator [ "--skip-routes" ]

    run_generator [ "--skip-routes" ]

    assert_equal 1, Dir.glob(File.join(destination_root, "db/migrate/*_create_active_agent_code_sessions.rb")).size
    assert_equal 1, Dir.glob(File.join(destination_root, "db/migrate/*_add_code_session_runner.rb")).size
    assert_operator migration_version("add_code_session_runner"), :>, migration_version("create_active_agent_code_sessions")
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

  test "a fresh install emits every shipped numbered template after the dashboard tables" do
    run_generator [ "--skip-routes" ]

    NUMBERED.each do |_template, name|
      assert_migration "db/migrate/#{name}.rb"
      assert_operator migration_version(name), :>, migration_version("add_code_session_runner"),
        "#{name} must run after every migration emitted before the numbered templates"
    end
    assert_equal NUMBERED.map(&:last).uniq.size, NUMBERED.size, "two numbered templates share a migration name"
    numbers = NUMBERED.map { |template, _name| File.basename(template)[0, 3] }
    assert_equal numbers.uniq.size, numbers.size, "two numbered templates share a number"
  end

  test "numbered templates are emitted in number order, with their ERB rendered" do
    with_numbered_templates(
      "002_add_widget_color.rb.erb" => numbered_template("AddWidgetColor"),
      "001_create_widgets.rb.erb" => numbered_template("CreateWidgets"),
      "010_add_widget_size.rb.erb" => numbered_template("AddWidgetSize")
    ) do
      run_generator [ "--skip-routes" ]
    end

    assert_migration "db/migrate/create_widgets.rb" do |content|
      assert_match(/class CreateWidgets < ActiveRecord::Migration\[\d+\.\d+\]/, content)
    end
    versions = %w[create_widgets add_widget_color add_widget_size].map { |name| migration_version(name) }
    assert_equal versions.sort, versions, "emitted in NNN order"
    assert_operator versions.first, :>, migration_version("create_active_agent_dashboard_tables")
  end

  test "files in the numbered template directory that break the naming convention are not emitted" do
    with_numbered_templates(
      "001_create_widgets.rb.erb" => numbered_template("CreateWidgets"),
      "7_misnumbered.rb.erb" => numbered_template("Misnumbered"),
      "002_Capitalized.rb.erb" => numbered_template("Capitalized"),
      "003_no_extension.rb" => numbered_template("NoExtension"),
      "README.md" => "notes\n"
    ) do
      run_generator [ "--skip-routes" ]
    end

    assert_migration "db/migrate/create_widgets.rb"
    emitted = Dir.children(File.join(destination_root, "db/migrate")).map { |file| file.sub(/\A\d+_/, "") }
    assert_empty emitted & %w[misnumbered.rb Capitalized.rb capitalized.rb no_extension.rb README.md]
  end

  test "a numbered migration the app already has is not emitted again" do
    migrate = File.join(destination_root, "db/migrate")
    FileUtils.mkdir_p(migrate)
    File.write(File.join(migrate, "20250101000000_create_widgets.rb"), "# already installed\n")

    with_numbered_templates(
      "001_create_widgets.rb.erb" => numbered_template("CreateWidgets"),
      "002_add_widget_color.rb.erb" => numbered_template("AddWidgetColor")
    ) do
      run_generator [ "--skip-routes" ]
      run_generator [ "--skip-routes" ]
    end

    assert_equal [ "20250101000000_create_widgets.rb" ], Dir.glob("*_create_widgets.rb", base: migrate)
    assert_equal 1, Dir.glob("*_add_widget_color.rb", base: migrate).size
  end

  test "a traces-only install emits no numbered template" do
    with_numbered_templates("001_create_widgets.rb.erb" => numbered_template("CreateWidgets")) do
      run_generator [ "--skip-routes", "--traces-only" ]
    end

    assert_no_migration "db/migrate/create_widgets.rb"
  end

  test "a missing numbered template directory emits nothing" do
    ActionAgent::InstallGenerator.numbered_migrations_path = File.join(destination_root, "no-such-directory")

    assert_equal [], ActionAgent::InstallGenerator.numbered_migrations
  ensure
    ActionAgent::InstallGenerator.numbered_migrations_path = nil
  end

  private

  # Points the generator at a directory holding +files+ (name => content)
  # for the block.
  def with_numbered_templates(files)
    Dir.mktmpdir("numbered-migrations") do |dir|
      files.each { |name, content| File.write(File.join(dir, name), content) }
      ActionAgent::InstallGenerator.numbered_migrations_path = dir
      yield
    ensure
      ActionAgent::InstallGenerator.numbered_migrations_path = nil
    end
  end

  def numbered_template(class_name)
    <<~ERB
      class #{class_name} < ActiveRecord::Migration<%= migration_version %>
        def change
        end
      end
    ERB
  end

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
