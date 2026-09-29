# frozen_string_literal: true

require "test_helper"

class LocalSandboxDatabasesTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("sandbox-databases"))
    @app = @root.join("app")
    @app.join("config").mkpath
  end

  teardown { FileUtils.rm_rf(@root) }

  test "cleanup selects only recorded databases, excluding overrides and replicas" do
    entries = {
      "primary" => database("app"), "queue" => database("queue"),
      "primary_replica" => database("app", "replica" => true),
      "external" => { "url" => "postgresql:///external" }
    }
    overrides = { "QUEUE_DATABASE_URL" => "postgresql:///preserved_queue" }
    plan = plan_for(entries, overrides: overrides)

    assert_equal({ "primary" => "postgresql:///app_sandbox_abcdef12" }, plan.drop_targets)
    dropped, checked = cleanup(entries, plan, overrides: overrides)
    assert_equal [ "app_sandbox_abcdef12" ], dropped
    assert_equal dropped, checked, "protection checks must not connect to excluded databases either"
  end

  test "cleanup ignores explicit URLs and new databases added after boot" do
    entries = { "primary" => database("app"), "queue" => database("queue") }
    plan = plan_for(entries)
    edited = entries.deep_dup
    edited["primary"]["url"] = "postgresql:///do_not_drop"
    edited["new_database"] = database("also_preserved")

    dropped, = cleanup(edited, plan)
    assert_equal [ "queue_sandbox_abcdef12" ], dropped
  end

  test "cleanup does not drop an unrecorded database with the same name but a different URL" do
    entries = { "primary" => database("app") }
    plan = plan_for(entries)
    entries["primary"]["url"] = "postgresql://other.example/app_sandbox_abcdef12"

    assert_empty cleanup(entries, plan).first
  end

  test "the cleanup script runs in a real Rails process and preserves unrecorded sqlite databases" do
    require "open3"
    require "sqlite3"
    managed = @root.join("managed.sqlite3")
    preserved = @root.join("preserved.sqlite3")
    [ managed, preserved ].each do |path|
      SQLite3::Database.new(path.to_s).tap do |db|
        db.execute("CREATE TABLE sentinel (id INTEGER)")
        db.close
      end
    end
    config = { "test" => {
      "primary" => { "adapter" => "sqlite3", "database" => managed.to_s },
      "preserved" => { "adapter" => "sqlite3", "database" => preserved.to_s }
    } }
    url = "sqlite3:#{managed}"
    script = "ActiveRecord::Base.configurations = #{config.inspect}\n" + ActionAgent::LocalSandboxBackend::DATABASE_DROP_SCRIPT
    env = {
      "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => Bundler.default_gemfile.to_s, "DATABASE_URL" => url,
      ActionAgent::LocalSandboxBackend::DATABASE_DROP_TARGETS_ENV => { "primary" => url }.to_json
    }

    output, status = Open3.capture2e(env, RbConfig.ruby, "bin/rails", "runner", script, chdir: Rails.root.to_s)

    assert status.success?, output
    assert_not managed.exist?, output
    assert preserved.exist?, "an unrecorded database was deleted"
  end

  test "legacy state without an explicit cleanup list never invokes database tasks" do
    @app.join("bin").mkpath
    @app.join("bin/rails").write("unused")
    @root.join("state.json").write({ "drop_databases" => true, "database_env" => { "DATABASE_URL" => "postgresql:///old_sandbox" } }.to_json)
    backend = ActionAgent::LocalSandboxBackend.new

    backend.stub(:capture, ->(*) { flunk "legacy state must not guess which databases to drop" }) do
      assert_nil backend.send(:drop_databases, @root)
    end
  end

  test "replicas follow their own writer regardless of configuration order" do
    plan = plan_for({
      "queue_replica" => database("queue", "replica" => true, "host" => "read.example"),
      "primary_replica" => database("app", "replica" => true),
      "queue" => database("queue", "host" => "write.example"),
      "primary" => database("app")
    })

    assert_equal plan.env["QUEUE_DATABASE_URL"], plan.env["QUEUE_REPLICA_DATABASE_URL"]
    assert_equal plan.env["DATABASE_URL"], plan.env["PRIMARY_REPLICA_DATABASE_URL"]
    assert_not_equal plan.env["DATABASE_URL"], plan.env["QUEUE_REPLICA_DATABASE_URL"]
    assert_equal %w[primary queue], plan.drop_targets.keys.sort
  end

  test "sqlite replicas share the file their writer uses" do
    plan = plan_for({
      "primary" => database("app.sqlite3", "adapter" => "sqlite3"),
      "queue" => database("queue.sqlite3", "adapter" => "sqlite3"),
      "queue_replica" => database("queue.sqlite3", "adapter" => "sqlite3", "replica" => true)
    })

    assert_equal plan.env["QUEUE_DATABASE_URL"], plan.env["QUEUE_REPLICA_DATABASE_URL"]
    assert_empty plan.drop_targets
  end

  test "a replica follows its writer's explicit override without making it droppable" do
    plan = plan_for({ "primary" => database("app"), "replica" => database("app", "replica" => true) },
      overrides: { "DATABASE_URL" => "postgresql:///chosen_by_owner" })

    assert_equal "postgresql:///chosen_by_owner", plan.env["REPLICA_DATABASE_URL"]
    assert_empty plan.drop_targets
  end

  test "ambiguous replica mappings refuse boot instead of choosing an unrelated database" do
    entries = {
      "primary" => database("app", "host" => "one.example"),
      "other" => database("app", "host" => "two.example"),
      "replica" => database("app", "replica" => true)
    }
    error = assert_raises(ArgumentError) { plan_for(entries) }
    assert_match(/set REPLICA_DATABASE_URL/, error.message)
  end

  test "different ERB database expressions are not treated as the same database" do
    error = assert_raises(ArgumentError) do
      plan_for({
        "primary" => database('<%= ENV.fetch("PRIMARY_DB") %>'),
        "replica" => database('<%= ENV.fetch("REPLICA_DB") %>', "replica" => true)
      })
    end
    assert_match(/cannot identify a unique sandbox database/, error.message)
  end

  private

  def database(name, options = {})
    { "adapter" => "postgresql", "database" => name }.merge(options)
  end

  def plan_for(entries, overrides: {})
    @app.join("config/database.yml").write({ "test" => entries }.to_yaml)
    ActionAgent::LocalSandboxDatabases.plan(app: @app, workspace: @root, session_id: "abcdef12-3456",
      overrides: overrides.merge("RAILS_ENV" => "test"))
  end

  # The exact script run by bin/rails runner, using real Rails URL/config
  # resolution and intercepting only database protection/DDL operations.
  def cleanup(entries, plan, overrides: {})
    original_configs = ActiveRecord::Base.configurations
    env = overrides.merge(plan.env).merge(
      ActionAgent::LocalSandboxBackend::DATABASE_DROP_TARGETS_ENV => plan.drop_targets.to_json
    )
    original_env = env.keys.index_with { |key| ENV[key] }
    env.each { |key, value| ENV[key] = value }
    ActiveRecord::Base.configurations = { "test" => entries }
    dropped = []
    checked = []
    tasks = ActiveRecord::Tasks::DatabaseTasks
    tasks.stub(:check_protected_environments!, ->(environment) {
      checked.concat(ActiveRecord::Base.configurations.configs_for(env_name: environment).map(&:database))
    }) do
      tasks.stub(:drop, ->(config) { dropped << config.database }) do
        Object.new.instance_eval(ActionAgent::LocalSandboxBackend::DATABASE_DROP_SCRIPT)
      end
    end
    [ dropped, checked ]
  ensure
    ActiveRecord::Base.configurations = original_configs
    original_env&.each { |key, value| ENV[key] = value }
  end
end
