# frozen_string_literal: true

require "test_helper"
require "erb"
require "generators/action_agent/install_generator"

# The code sessions migration only ever exists as an ERB template, so nothing
# else in the suite compiles it: a stray `<%` or an unbalanced `end` would
# ship and only fail in a host app running `rails generate action_agent:install`.
# The install generator is the one thing that emits it, so it is checked here
# too — a template nobody copies is the same outage as a broken one.
class ActionAgentCodeSessionsGeneratorTest < ActiveSupport::TestCase
  GENERATOR_ROOT = File.expand_path("../lib/generators/action_agent", __dir__)
  TEMPLATE = File.join(GENERATOR_ROOT, "templates", "create_active_agent_code_sessions.rb.erb")
  INSTALL_GENERATOR = File.join(GENERATOR_ROOT, "install_generator.rb")

  # The generator renders with a binding that supplies migration_version, the
  # same way migration_template does.
  def render(migration_version: "[7.2]")
    ERB.new(File.read(TEMPLATE), trim_mode: "-").result_with_hash(migration_version: migration_version)
  end

  test "the migration template renders to Ruby that parses" do
    source = render

    assert_nothing_raised { RubyVM::InstructionSequence.compile(source) }
    assert_not_includes source, "<%", "nothing should be left unrendered"
  end

  test "the rendered migration is the class Rails will load, at the version it was told" do
    assert_includes render, "class CreateActiveAgentCodeSessions < ActiveRecord::Migration[7.2]"
    assert_includes render(migration_version: "[8.0]"), "ActiveRecord::Migration[8.0]"
    assert_nothing_raised { RubyVM::InstructionSequence.compile(render(migration_version: "[8.0]")) }
  end

  # The table name follows ActionAgent.table_name_prefix, which a host app
  # that grew these tables unprefixed sets to "" — so the migration reads it
  # rather than hard-coding the name the models would then disagree with.
  test "the migration builds its table name from the configured prefix" do
    source = render

    assert_includes source, "prefix = ActionAgent.table_name_prefix"
    assert_includes source, 'create_table "#{prefix}code_sessions"'
    assert_includes source, "t.index :session_id, unique: true"
  end

  # No credential is a column: a leaked row leaks a task and a transcript,
  # never a way to push to someone's repository.
  test "the migration creates no credential column" do
    columns = render[/create_table.*?^    end$/m]

    assert columns.present?, "the create_table block should be rendered"
    # input_tokens and output_tokens are counts; nothing here holds a value.
    assert_not_includes columns, "github_token"
    assert_not_includes columns, "access_token"
    assert_not_includes columns, "credential"
    assert_not_includes columns, "secret"
    assert_includes columns, "t.string :github_access", "only what the session may do, never what it does it with"
  end

  test "the install generator emits the code sessions migration" do
    assert_includes ActionAgent::InstallGenerator.public_instance_methods(false), :copy_migrations

    body = File.read(INSTALL_GENERATOR)[/^    def copy_migrations$(.*?)^    end$/m, 1]

    assert body.present?, "copy_migrations should still be a method in #{INSTALL_GENERATOR}"
    assert_includes body, "create_active_agent_code_sessions.rb.erb"
    assert_includes body, "db/migrate/create_active_agent_code_sessions.rb"
    # An install that predates code sessions still needs this migration, and
    # re-emitting one it already has aborts the whole generator.
    assert_includes body, 'existing_migration?("create_active_agent_code_sessions")'
  end

  test "the template the generator names is the one that exists on disk" do
    assert_path_exists TEMPLATE
    assert_equal File.join(ActionAgent::InstallGenerator.source_root, "create_active_agent_code_sessions.rb.erb"), TEMPLATE
  end
end
