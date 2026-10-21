# frozen_string_literal: true

require "test_helper"
require "open3"

# The :local backend's writing verbs — run_command, list_files, write_file —
# and CheckoutTools, which the terminal, filesystem, edit and database
# capabilities call through the orchestrator, against a real git checkout
# laid out as a boot leaves one.
class LocalSandboxCheckoutToolsTest < ActiveSupport::TestCase
  Backend = ActionAgent::LocalSandboxBackend
  CHECKOUT_TOKEN = "ghs_#{'D' * 36}"

  # What CheckoutTools and the backend read off a SandboxSession.
  SandboxDouble = Struct.new(:session_id, :checkout_spec, :status, keyword_init: true) do
    def ready? = status == "ready"
    def running? = status == "running"
  end

  def setup
    super
    @tmp = Pathname(Dir.mktmpdir("local-checkout-tools")).realpath
    @saved = {
      enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled),
      root: ActionAgent.instance_variable_get(:@local_sandbox_root)
    }
    ActionAgent.local_sandboxes_enabled = true
    ActionAgent.local_sandbox_root = @tmp.join("sandboxes").to_s
    @sandbox = SandboxDouble.new(session_id: SecureRandom.uuid, checkout_spec: { token: CHECKOUT_TOKEN }, status: "ready")
    @workspace = @tmp.join("sandboxes", @sandbox.session_id)
    @app = @workspace.join("app")
    @backend = Backend.new
    checkout!("README.md" => "# Shop\n", ".gitignore" => "log/\n", "app/models/order.rb" => "class Order; end\n")
  end

  def teardown
    ActionAgent.instance_variable_set(:@local_sandboxes_enabled, @saved[:enabled])
    ActionAgent.instance_variable_set(:@local_sandbox_root, @saved[:root])
    FileUtils.rm_rf(@tmp)
    super
  end

  test "run_command runs in the checkout with the boot's database variables and scrubs the sandbox's secrets" do
    @workspace.join("state.json").write(JSON.generate("database_env" => { "DATABASE_URL" => "sqlite3:db/sandbox.sqlite3" }))

    result = @backend.run_command(@sandbox, "pwd; echo $DATABASE_URL; echo #{CHECKOUT_TOKEN}; echo oops >&2; exit 3")

    lines = result[:output].lines.map(&:strip)
    assert_equal @app.to_s, lines[0]
    assert_equal "sqlite3:db/sandbox.sqlite3", lines[1]
    assert_not_includes result[:output], CHECKOUT_TOKEN
    assert_includes lines, "oops"
    assert_equal 3, result[:exit_status]
    assert_equal false, result[:timed_out]
  end

  test "run_command stops a command at its timeout" do
    result = @backend.run_command(@sandbox, "sleep 5", timeout: 1)

    assert_nil result[:exit_status]
    assert result[:timed_out]
  end

  test "list_files lists tracked and untracked files without ignored ones" do
    write("app/models/item.rb", "class Item; end\n")
    write("log/development.log", "ignored\n")

    assert_equal %w[.gitignore README.md app/models/item.rb app/models/order.rb], @backend.list_files(@sandbox)[:files].sort
    assert_equal %w[app/models/item.rb app/models/order.rb], @backend.list_files(@sandbox, "app/models/")[:files].sort
    assert_raises(Backend::Error) { @backend.list_files(@sandbox, "../outside") }
  end

  test "write_file creates directories and files, and replaces only regular files inside the checkout" do
    result = @backend.write_file(@sandbox, "lib/tasks/report.rake", "task :report\n")

    assert_equal({ path: "lib/tasks/report.rake", bytes: 13, created: true }, result)
    assert_equal "task :report\n", @app.join("lib/tasks/report.rake").read
    assert_equal false, @backend.write_file(@sandbox, "README.md", "# Shop v2\n")[:created]

    outside = @tmp.join("outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside.to_s, @app.join("linked").to_s)
    assert_raises(Backend::Error) { @backend.write_file(@sandbox, "linked/evil.rb", "x") }
    assert_not outside.join("evil.rb").exist?
    assert_raises(Backend::Error) { @backend.write_file(@sandbox, ".git/config", "x") }
    assert_raises(Backend::Error) { @backend.write_file(@sandbox, "/etc/passwd", "x") }
  end

  test "the checkout tools reach the backend through the orchestrator" do
    tools = ActionAgent::CheckoutTools.new(@sandbox, orchestrator: ActionAgent::SandboxOrchestrator.new(backend: "local"))

    assert_equal "# Shop\n", tools.call("read_file", { path: "README.md" })[:content]
    assert_includes tools.call("list_files", {})[:files], "app/models/order.rb"
    assert tools.call("write_file", { path: "notes.txt", content: "hello\n" })[:created]
    assert_equal 0, tools.call("run_command", { command: "test -f notes.txt" })[:exit_status]

    assert_equal 1, tools.call("edit_file", { path: "app/models/order.rb", old_text: "class Order", new_text: "class Order < ApplicationRecord" })[:replaced]
    assert_equal "class Order < ApplicationRecord; end\n", @app.join("app/models/order.rb").read
    assert_match(/was not found/, tools.call("edit_file", { path: "README.md", old_text: "nope", new_text: "x" })[:error])
    write("twice.txt", "a a\n")
    assert_match(/appears 2 times/, tools.call("edit_file", { path: "twice.txt", old_text: "a", new_text: "b" })[:error])
    assert_match(/does not exist/, tools.call("read_file", { path: "missing.rb" })[:error])
  end

  test "query_database reads the result its script prints after the marker" do
    orchestrator = Minitest::Mock.new
    payload = { columns: %w[id], rows: [ [ 1 ] ], row_count: 1, truncated: false }
    orchestrator.expect(:run_command, { output: "booting...\n#{ActionAgent::CheckoutTools::QUERY_MARKER}#{payload.to_json}\n", exit_status: 0 }) do |sandbox, command, timeout:|
      sandbox == @sandbox && command.start_with?("bin/rails runner ") && !command.include?("SELECT") && timeout == ActionAgent::CheckoutTools::QUERY_TIMEOUT
    end

    result = ActionAgent::CheckoutTools.new(@sandbox, orchestrator: orchestrator).call("query_database", { sql: "SELECT 1 AS id" })

    assert_equal({ "columns" => %w[id], "rows" => [ [ 1 ] ], "row_count" => 1, "truncated" => false }, result)
    orchestrator.verify
  end

  test "without a live checkout the tools say how to give the run one" do
    assert_match(/no checkout sandbox/, ActionAgent::CheckoutTools.new(nil).call("run_command", { command: "ls" })[:error])
    @sandbox.status = "expired"
    assert_match(/is expired/, ActionAgent::CheckoutTools.new(@sandbox).call("read_file", { path: "README.md" })[:error])
  end

  private

  def checkout!(files)
    FileUtils.mkdir_p(@app)
    git("init", "-q")
    files.each { |path, content| write(path, content) }
    git("add", "--all")
    git("commit", "-q", "-m", "Initial")
    @workspace.join("state.json").write(JSON.generate("checkout_commit" => git("rev-parse", "HEAD").strip))
  end

  def write(path, content)
    file = @app.join(path)
    FileUtils.mkdir_p(file.dirname)
    file.write(content)
  end

  def git(*args)
    env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }
    argv = [ "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
      "-c", "init.defaultBranch=main", *args ]
    output, status = Open3.capture2e(env, *argv, chdir: @app.to_s)
    assert status.success?, "git #{args.join(' ')} failed: #{output}"
    output
  end
end
