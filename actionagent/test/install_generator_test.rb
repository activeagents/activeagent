# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/action_agent/install_generator"

# The dashboard's install generator, run into a scratch directory: a fresh
# install gets every migration the engine's models need, and re-running it on
# an install from before a table shipped adds just that table (#489).
class ActionAgentInstallGeneratorTest < Rails::Generators::TestCase
  tests ActionAgent::InstallGenerator
  destination Rails.root.join("tmp/install_generator")
  setup :prepare_destination
  teardown { FileUtils.rm_rf(destination_root) }

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

  test "an install that predates Claude Code sessions gets their table alone" do
    migrate = File.join(destination_root, "db/migrate")
    FileUtils.mkdir_p(migrate)
    %w[
      create_active_agent_telemetry_traces add_agent_id_to_active_agent_telemetry_traces add_agent_releases
      create_active_agent_dashboard_tables create_active_agent_evaluation_scenarios create_active_agent_github_connections
    ].each_with_index do |name, index|
      File.write(File.join(migrate, "2025010100000#{index}_#{name}.rb"), "# already installed\n")
    end

    run_generator [ "--skip-routes" ]

    assert_migration "db/migrate/create_active_agent_code_sessions.rb"
    emitted = Dir.children(migrate).reject { |file| file.start_with?("2025010100000") }
    assert_equal 1, emitted.size, "only the missing migration is emitted: #{emitted.inspect}"
    assert_equal 1, Dir.glob(File.join(migrate, "*_create_active_agent_github_connections.rb")).size
  end

  test "an install that has the table is not given a second one" do
    run_generator [ "--skip-routes" ]

    run_generator [ "--skip-routes" ]

    assert_equal 1, Dir.glob(File.join(destination_root, "db/migrate/*_create_active_agent_code_sessions.rb")).size
  end
end
