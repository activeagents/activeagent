# frozen_string_literal: true

require "test_helper"

# The :local sandbox backend end to end: a throwaway git repository is cloned
# over file://, booted through its .activeagents/sandbox.yml with the fake app
# server and manifest in test/support/local_sandbox, and Claude Code sessions
# run the fake CLI there. Real processes, real ports, real signals; only the
# sandbox session and code session records are doubles (#489).
class LocalSandboxBackendTest < ActiveSupport::TestCase
  Backend = ActionAgent::LocalSandboxBackend

  FIXTURES = File.expand_path("support/local_sandbox", __dir__)
  GITHUB_TOKEN = "ghs_fixtureCheckoutToken0123456789abcdef"
  CLAUDE_CREDENTIAL = "sk-ant-oat01-fixtureCredential-0123456789"
  MCP_TOKEN = "fixture-mcp-token-0123456789"
  # What an Authorization: Basic header for the checkout would carry.
  BASIC_AUTH = [ "x-access-token:#{GITHUB_TOKEN}" ].pack("m0")

  SandboxDouble = Struct.new(:session_id, :sandbox_type, :checkout_spec, :runtime_environment, keyword_init: true) do
    def app_runtime?
      sandbox_type == "app_runtime"
    end
  end
  CodeSessionDouble = Struct.new(:id, :prompt, :model, keyword_init: true)

  CONFIG = %i[
    local_sandbox_boot_timeout claude_code_command claude_code_permission_mode claude_code_max_turns claude_code_timeout
  ].freeze

  def setup
    super
    @tmp = Pathname(Dir.mktmpdir("local-sandbox-test")).realpath
    @pids_to_reap = []
    @saved_config = CONFIG.index_with { |name| ActionAgent.public_send(name) }.merge(
      local_sandboxes_enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled),
      local_sandbox_root: ActionAgent.instance_variable_get(:@local_sandbox_root)
    )
    ActionAgent.local_sandboxes_enabled = true
    ActionAgent.local_sandbox_root = @tmp.join("sandboxes").to_s
    ActionAgent.local_sandbox_boot_timeout = 20
    ActionAgent.claude_code_timeout = 20
    ActionAgent.claude_code_max_turns = nil
    ActionAgent.claude_code_permission_mode = "acceptEdits"
    ActionAgent.claude_code_command = fake_claude_command

    # The readiness probe and these tests talk to the booted fixture over
    # loopback, which VCR and WebMock refuse by default.
    config = WebMock::Config.instance
    @webmock = [ config.allow_net_connect, config.allow_localhost, config.allow, config.net_http_connect_on_start ]
    VCR.turn_off!
    WebMock.disable_net_connect!(allow_localhost: true)

    @backend = Backend.new
  end

  def teardown
    # Whatever a test left running goes, even when the backend's own stopping
    # is what broke: its recorded groups, then every pid a test learned.
    root = ActionAgent.local_sandbox_root
    if root.directory?
      root.children.each do |dir|
        @pids_to_reap << recorded_server_group(dir)
        @backend.terminate("local-#{dir.basename}")
      end
    end
    @pids_to_reap.compact.each { |pid| reap(pid) }

    @saved_config.each { |name, value| ActionAgent.public_send("#{name}=", value) }
    VCR.turn_on!
    config = WebMock::Config.instance
    config.allow_net_connect, config.allow_localhost, config.allow, config.net_http_connect_on_start = @webmock
    FileUtils.rm_rf(@tmp)
    super
  end

  test "boots a checkout whose MCP endpoint answers, and terminate stops it" do
    sandbox = sandbox_double(create_origin!)
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "local")

    result = orchestrator.create_sandbox(sandbox)

    handle = "local-#{sandbox.session_id}"
    assert_equal handle, result[:sandbox_id]
    assert_equal "local", result[:backend]
    assert_match %r{\Ahttp://127\.0\.0\.1:\d+/activeagents/mcp\z}, result[:mcp_url]
    assert_equal MCP_TOKEN, result[:mcp_token]
    assert_equal result[:mcp_url].delete_suffix("/activeagents/mcp"), result[:url]

    uri = URI(result[:mcp_url])
    assert_equal "405", http(uri) { |http| http.get(uri.path, "Accept" => "application/json") }.code
    assert_equal "401", rpc(uri, token: nil).code
    assert_equal "401", rpc(uri, token: "not-the-token").code
    response = rpc(uri, token: MCP_TOKEN)
    assert_equal "200", response.code
    assert_equal "fixture_tool", JSON.parse(response.body).dig("result", "tools", 0, "name")

    status = orchestrator.status(handle)
    assert_equal "running", status[:status]
    assert_equal uri.port, status[:port]
    assert_includes orchestrator.list_sandboxes.map { |entry| entry[:container_name] }, handle
    assert orchestrator.supports?(:code_session)

    workspace = workspace(sandbox)
    assert_equal %w[app claude logs runtime.json state.json state.lock], workspace.children.map { |child| child.basename.to_s }.sort
    assert_equal %w[checkout.log manifest.log server.log setup.log], workspace.join("logs").children.map { |log| log.basename.to_s }.sort

    # The token reached the fetch and nothing else: not the repository's
    # config, not a log, not any file the checkout or its processes wrote.
    git_config = workspace.join("app/.git/config").read
    assert_includes git_config, sandbox.checkout_spec[:clone_url]
    workspace.glob("**/*", File::FNM_DOTMATCH).select(&:file?).each do |file|
      content = file.binread
      assert_not_includes content, GITHUB_TOKEN, "#{file} carries the checkout token"
      assert_not_includes content, BASIC_AUTH, "#{file} carries the checkout credentials"
    end

    record = server_record(workspace)
    state = JSON.parse(workspace.join("state.json").read)
    assert_equal status[:pid], state["pid"]
    assert_equal({}, state["code_sessions"])
    assert_equal state["pid"], record["pgid"], "the server leads its own process group"
    # The real Bundler snapshot (the test's DATABASE_URL came from the command
    # line) never reaches the server either.
    assert_not record["env"].key?("DATABASE_URL")

    assert orchestrator.terminate(handle)

    assert_gone record["pid"], record["child_pid"]
    assert_not workspace.exist?
    assert orchestrator.terminate(handle), "terminate is idempotent"
    assert_equal "not_found", orchestrator.status(handle)[:status]
    assert_empty orchestrator.list_sandboxes
  end

  test "sandbox processes inherit none of the dashboard's secrets" do
    dashboard_secrets = {
      "DATABASE_URL" => "postgres://dashboard:hunter2@db.internal/dashboard",
      "CACHE_DATABASE_URL" => "postgres://dashboard:hunter2@db.internal/cache",
      "REDIS_URL" => "redis://db.internal:6379/0",
      "SECRET_KEY_BASE" => "dashboard-secret-key-base-0123456789",
      "RAILS_MASTER_KEY" => "dashboard-master-key-0123456789",
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "dashboard-encryption-key",
      "OPENAI_API_KEY" => "sk-dashboard-openai-0123456789",
      "ANTHROPIC_API_KEY" => "sk-ant-api03-dashboard-0123456789",
      "GITHUB_TOKEN" => "ghp_dashboardsOwnToken0123456789",
      "RAILS_ENV" => "production",
      "PORT" => "3000"
    }

    result = with_env(dashboard_secrets) do
      # Bundler's snapshot predates these assignments; hand the backend the
      # environment as the test now has it (with its Bundler and Ruby
      # variables too) as the dashboard's.
      Bundler.stub(:unbundled_env, ENV.to_h) { @backend.create_sandbox(sandbox_double(create_origin!)) }
    end

    workspace = ActionAgent.local_sandbox_root.children.first
    server_env = server_record(workspace)["env"]
    setup_env = workspace.join("app/tmp/setup_env.txt").read.lines.to_h { |line| line.chomp.split("=", 2) }

    { "server" => server_env, "setup" => setup_env }.each do |step, env|
      (dashboard_secrets.keys - [ "PORT" ]).each do |name|
        assert_not env.key?(name), "#{step} inherited #{name}"
      end
      %w[BUNDLE_GEMFILE RUBYOPT RUBYLIB].each { |name| assert_not env.key?(name), "#{step} inherited #{name}" }
      assert_empty env.keys.grep(/\ABUNDLER?_/), "#{step} inherited Bundler's variables"
      env.each_value do |value|
        [ GITHUB_TOKEN, CLAUDE_CREDENTIAL, *dashboard_secrets.except("PORT", "RAILS_ENV").values ].each do |secret|
          assert_not_includes value, secret, "#{step} saw a secret"
        end
      end

      assert_equal ENV["PATH"], env["PATH"]
      assert_equal ENV["HOME"], env["HOME"]
      assert_equal "local", env["FIXTURE_FLAVOR"], "sandbox.yml's env reaches #{step}"
      assert_equal workspace.basename.to_s, env["ACTION_AGENT_SANDBOX_SESSION_ID"]
      assert_equal workspace.join("runtime.json").to_s, env["ACTION_AGENT_SANDBOX_MANIFEST"]
    end

    assert_equal URI(result[:mcp_url]).port.to_s, server_env["PORT"], "the sandbox's own port, not the dashboard's"
    assert_not setup_env.key?("PORT"), "setup runs before the port is chosen"
  end

  test "the sanitized environment drops the dashboard's database, keys and credentials" do
    source = {
      "PATH" => "/usr/bin", "HOME" => "/home/dev", "LANG" => "en_US.UTF-8", "TMPDIR" => "/tmp",
      "HTTPS_PROXY" => "http://proxy:3128", "SSL_CERT_FILE" => "/etc/ssl/cert.pem", "CURL_CA_BUNDLE" => "/etc/ssl/ca.pem",
      "RBENV_VERSION" => "3.3.6", "MISE_SHELL" => "zsh", "ASDF_DIR" => "/home/dev/.asdf",
      "DATABASE_URL" => "x", "QUEUE_DATABASE_URL" => "x", "REDIS_URL" => "x", "SECRET_KEY_BASE" => "x",
      "RAILS_MASTER_KEY" => "x", "RAILS_ENV" => "x", "RACK_ENV" => "x", "PORT" => "x",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "x", "BUNDLE_GEMFILE" => "x", "BUNDLE_PATH" => "x",
      "BUNDLER_ORIG_PATH" => "x", "RUBYOPT" => "x", "RUBYLIB" => "x",
      "AWS_SECRET_ACCESS_KEY" => "x", "AWS_ACCESS_KEY_ID" => "x", "GH_TOKEN" => "x", "PGPASSWORD" => "x",
      "MYSQL_PASSWD" => "x", "STRIPE_APIKEY" => "x", "SSH_PRIVATE_KEY" => "x", "GOOGLE_CREDENTIALS" => "x",
      "openai_api_key" => "x", "GIT_DIR" => "x", "GIT_INDEX_FILE" => "x", "GIT_CONFIG_KEY_0" => "x",
      # A dashboard run from inside Claude Code: its session, and a base URL
      # that would redirect the owner's credential.
      "CLAUDECODE" => "1", "CLAUDE_CODE_SESSION_ID" => "x", "CLAUDE_CODE_ENTRYPOINT" => "x",
      "CLAUDE_CONFIG_DIR" => "x", "ANTHROPIC_BASE_URL" => "https://elsewhere.test", "OPENAI_BASE_URL" => "x",
      "OLLAMA_HOST" => "x", "CLAUDETTE_HOME" => "/home/dev/claudette",
      # Secrets without a telltale word in their name.
      "DB_PASS" => "x", "MYSQL_PWD" => "x", "LOCKBOX_MASTER_KEY" => "x", "SENTRY_DSN" => "x",
      "SLACK_WEBHOOK_URL" => "x", "GITHUB_PAT" => "x", "CACHE_STORE" => "redis://:hunter2@cache:6379/0",
      # A token as a URL's username, with no password; and one further in.
      "UPSTREAM_REPO" => "https://ghp_abc0123456789@github.com/acme/shop.git",
      "MIRRORS" => "git://mirror.test/shop https://x-access-token:ghs_abc@github.com/acme/shop",
      # The dashboard's own git configuration, and its SSH agent: the
      # checkout's code has no business with either.
      "GIT_CONFIG_GLOBAL" => "/home/dev/.gitconfig", "GIT_CONFIG_SYSTEM" => "/etc/gitconfig", "GIT_CONFIG_NOSYSTEM" => "1",
      "SSH_AUTH_SOCK" => "/tmp/ssh-agent.sock",
      # An @ that is not a URL's userinfo stays.
      "DOCS_URL" => "https://example.com/users/@me", "EMAIL" => "dev@example.com"
    }

    env = Backend.sanitized_environment(source)

    assert_equal %w[
      ASDF_DIR CLAUDETTE_HOME CURL_CA_BUNDLE DOCS_URL EMAIL HOME HTTPS_PROXY LANG MISE_SHELL PATH RBENV_VERSION SSL_CERT_FILE
      TMPDIR
    ], env.keys.sort
  end

  test "run_code_session streams events, returns the diff and scrubs the credential" do
    sandbox = boot!
    ActionAgent.claude_code_max_turns = 3
    events = []

    outcome = @backend.run_code_session(sandbox, code_session(prompt: "Edit the README, please", model: "claude-sonnet-4-5")) do |event|
      events << event
    end

    assert_equal 0, outcome[:exit_status]
    assert_equal %w[system assistant raw assistant result], events.map { |event| event["type"] }
    assert_equal "not json at all", events[2]["text"]
    assert_equal "Edit", events[3].dig("message", "content", 0, "name")
    assert_equal "Edited README.md", events.last["result"]
    assert_equal "My credential is [REDACTED]", events[1].dig("message", "content", 0, "text")
    assert_not_includes events.to_json, CLAUDE_CREDENTIAL

    diff = outcome[:diff]
    assert_includes diff, "+Edited by the fake Claude Code."
    assert_includes diff, "new file mode", "untracked files are diffed as intent-to-add"
    assert_includes diff, "+A new file the session wrote (credential: [REDACTED])."
    assert_includes diff, "deleted file mode", "a removed file is in the diff, although `add --all` staged its removal"
    assert_includes diff, "-Nothing needs this file."
    assert_not_includes diff, CLAUDE_CREDENTIAL
    assert_not_includes diff, "server.json", "ignored files stay out of the diff"

    assert_includes outcome[:stderr_tail], "fake claude: authenticating with [REDACTED]"
    assert_not_includes outcome[:stderr_tail], CLAUDE_CREDENTIAL
    workspace = workspace(sandbox)
    log = workspace.join("logs/claude-7.log").read
    assert_includes log, "authenticating with [REDACTED]"
    assert_not_includes log, CLAUDE_CREDENTIAL

    invocation = JSON.parse(workspace.join("claude/invocation.json").read)
    assert_equal [
      "-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
      "--no-session-persistence", "--permission-prompts", "none", "--max-turns", "3", "--model", "claude-sonnet-4-5"
    ], invocation["argv"]
    assert_equal "Edit the README, please", invocation["prompt"], "the prompt arrives on stdin"
    assert_equal workspace.join("app").realpath.to_s, File.realpath(invocation["cwd"])

    env = invocation["env"]
    assert_equal CLAUDE_CREDENTIAL, env["CLAUDE_CODE_OAUTH_TOKEN"]
    assert_equal workspace.join("claude").to_s, env["CLAUDE_CONFIG_DIR"]
    %w[DISABLE_AUTOUPDATER DISABLE_TELEMETRY DISABLE_ERROR_REPORTING CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC].each do |name|
      assert_equal "1", env[name], name
    end
    assert_not env.key?("DATABASE_URL")
    assert_not env.key?("FIXTURE_FLAVOR"), "sandbox.yml's env is for the app, not Claude Code"
    assert(env.values.none? { |value| value.include?(GITHUB_TOKEN) }, "Claude Code never sees the checkout token")

    assert_equal({}, JSON.parse(workspace.join("state.json").read)["code_sessions"])
  end

  test "a later session's diff still holds earlier changes, even ones it committed" do
    sandbox = boot!
    @backend.run_code_session(sandbox, code_session(id: 8)) { |_event| }

    outcome = @backend.run_code_session(sandbox, code_session(id: 9, prompt: "COMMIT everything")) { |_event| }

    assert_equal 0, outcome[:exit_status]
    app = workspace(sandbox).join("app")
    assert_equal "Committed by the fake Claude Code", `git -C #{app.to_s.shellescape} log -1 --format=%s`.strip
    diff = outcome[:diff]
    assert_includes diff, "+Edited by the fake Claude Code."
    assert_includes diff, "+A new file the session wrote (credential: [REDACTED])."
    assert_includes diff, "deleted file mode"
    assert_includes diff, "-Nothing needs this file."
  end

  test "a CLI without --permission-prompts is not given it, nor unset options" do
    ActionAgent.claude_code_command = fake_claude_command(legacy: true)
    sandbox = boot!

    outcome = @backend.run_code_session(sandbox, code_session) { |_event| }

    assert_equal 0, outcome[:exit_status]
    argv = JSON.parse(workspace(sandbox).join("claude/invocation.json").read)["argv"]
    assert_equal [
      "-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits", "--no-session-persistence"
    ], argv
  end

  test "cancel_code_session stops the session's whole process group" do
    sandbox = boot!
    session = code_session(id: 11, prompt: "SLEEP until cancelled")
    outcome = nil
    thread = Thread.new { outcome = @backend.run_code_session(sandbox, session) { |_event| } }
    thread.report_on_exception = false

    pids = wait_for_code_session(sandbox, "11")
    assert @backend.cancel_code_session(sandbox, session)

    assert thread.join(15), "the session did not end after cancel"
    assert_equal 143, outcome[:exit_status], "stopped by SIGTERM"
    assert_gone pids["pid"], pids["child_pid"]
    assert_equal({}, JSON.parse(workspace(sandbox).join("state.json").read)["code_sessions"])
    assert_equal "running", @backend.status("local-#{sandbox.session_id}")[:status], "the sandbox itself keeps running"
  end

  test "a cancel that comes before Claude Code starts keeps it from running" do
    sandbox = boot!
    session = code_session(id: 31, prompt: "SLEEP")

    # CodeSessionJob marked the session running, and the backend has not
    # started the CLI yet: there is no process to stop.
    assert @backend.cancel_code_session(sandbox, session)
    error = assert_raises(Backend::Error) { @backend.run_code_session(sandbox, session) { |_event| } }

    assert_equal "Claude Code session 31 was cancelled before it started", error.message
    assert_not workspace(sandbox).join("claude/invocation.json").exist?, "Claude Code never ran"
    state = JSON.parse(workspace(sandbox).join("state.json").read)
    assert_equal({}, state["code_sessions"])
    assert_equal({}, state["cancelled_code_sessions"], "an honoured cancel is forgotten")
  end

  test "a cancel that comes while Claude Code starts stops it as soon as it is recorded" do
    sandbox = boot!
    session = code_session(id: 32, prompt: "SLEEP")
    claude = nil
    # The cancel lands after the CLI was spawned but before its pid is in
    # state.json, from another backend as the controller's would be.
    after_spawn(@backend) do |pid|
      claude = pid
      assert Backend.new.cancel_code_session(sandbox, session)
      assert_includes read_json(workspace(sandbox).join("state.json"))["cancelled_code_sessions"], "32"
    end

    outcome = @backend.run_code_session(sandbox, session) { |_event| }

    assert_equal 143, outcome[:exit_status], "stopped by SIGTERM"
    assert_gone claude
    assert_not workspace(sandbox).join("claude/pids.json").exist?, "stopped before it got the prompt"
    state = JSON.parse(workspace(sandbox).join("state.json").read)
    assert_equal({}, state["code_sessions"])
    assert_equal({}, state["cancelled_code_sessions"])
  end

  test "a session that outlives claude_code_timeout is stopped and raises" do
    sandbox = boot!
    ActionAgent.claude_code_timeout = 3

    error = assert_raises(Backend::Error) do
      @backend.run_code_session(sandbox, code_session(id: 12, prompt: "SLEEP past the timeout")) { |_event| }
    end

    assert_match(/did not finish within 3s/, error.message)
    pids = JSON.parse(workspace(sandbox).join("claude/pids.json").read)
    assert_gone pids["pid"], pids["child_pid"]
    assert_equal({}, JSON.parse(workspace(sandbox).join("state.json").read)["code_sessions"])
  end

  test "terminate also stops a running Claude Code session" do
    sandbox = boot!
    workspace = workspace(sandbox)
    server = server_record(workspace)
    outcome = nil
    thread = Thread.new { outcome = @backend.run_code_session(sandbox, code_session(id: 13, prompt: "SLEEP")) { |_event| } }
    thread.report_on_exception = false
    claude = wait_for_code_session(sandbox, "13")

    assert @backend.terminate("local-#{sandbox.session_id}")

    assert thread.join(15), "the session did not end after terminate"
    assert_equal 143, outcome[:exit_status]
    assert_gone server["pid"], server["child_pid"], claude["pid"], claude["child_pid"]
    assert_not workspace.exist?
  end

  test "terminate also stops a Claude Code session that starts while it runs" do
    skip "needs /proc to find the sandbox's processes" unless File.exist?("/proc/self/environ")

    sandbox = boot!
    handle = "local-#{sandbox.session_id}"
    workspace = workspace(sandbox)
    server = server_record(workspace)
    claude = nil
    terminating = nil
    # The CLI is spawned, and before its pid is recorded a terminate (from
    # another backend, as the cleanup job's would be) reads state.json.
    after_spawn(@backend) do |pid|
      claude = pid
      terminating = Thread.new { Backend.new.terminate(handle) }
      wait_until { !workspace.join("state.json").exist? || read_json(workspace.join("state.json"))["terminating"] }
    end

    error = assert_raises(Backend::Error) { @backend.run_code_session(sandbox, code_session(id: 14, prompt: "SLEEP")) { |_event| } }

    assert_equal "The sandbox is being stopped, so Claude Code did not run", error.message
    assert terminating.join(15)&.value, "terminate did not finish"
    assert_gone claude, server["pid"], server["child_pid"]
    assert_not workspace.exist?
    wait_until(timeout: 5) { sandbox_processes(sandbox).empty? }
  end

  test "status reports a server that died on its own as stopped" do
    sandbox = boot!
    handle = "local-#{sandbox.session_id}"
    record = server_record(workspace(sandbox))

    Process.kill("KILL", -record["pgid"])
    assert_gone record["pgid"], record["pid"], record["child_pid"]

    status = @backend.status(handle)
    assert_equal "stopped", status[:status]
    assert_equal record["pgid"], status[:pid]
    assert @backend.terminate(handle)
    assert_not workspace(sandbox).exist?
  end

  test "terminate never signals a recorded pid that another process now holds" do
    skip "needs /proc to tell a reused pid apart" unless File.exist?("/proc/self/environ")

    # A process group this sandbox never started, as if its pid had been
    # reused after the dashboard restarted.
    stranger = Process.spawn("sleep", "600", pgroup: true)
    workspace = ActionAgent.local_sandbox_root.join(SecureRandom.uuid).tap(&:mkpath)
    workspace.join("state.json").write(JSON.generate("pid" => stranger, "port" => 1, "code_sessions" => { "1" => stranger }))

    assert_equal "stopped", @backend.status("local-#{workspace.basename}")[:status]
    assert @backend.terminate("local-#{workspace.basename}")

    assert_not workspace.exist?
    assert_not process_gone?(stranger), "an unrelated process was signalled"
  ensure
    Process.kill("KILL", stranger) if stranger
    Process.wait(stranger) if stranger
  end

  test "a server that retitles itself is still known as the sandbox's own" do
    skip "needs /proc to show a process's environment" unless File.exist?("/proc/self/environ")

    # A process title longer than argv (Ruby's `$0=`, setproctitle) is
    # written over the environment block, and the session id marker with it.
    start = "exec #{RbConfig.ruby.shellescape} -e '$0 = %q(x) * 400; load ARGV.shift' " \
      "#{File.join(FIXTURES, "fake_app_server.rb").shellescape}"
    sandbox = sandbox_double(create_origin!(sandbox_yml(start: start)))
    result = @backend.create_sandbox(sandbox)
    handle = result[:container_name]
    record = server_record(workspace(sandbox))
    leader = record["pid"]
    if File.binread("/proc/#{leader}/environ").include?("ACTION_AGENT_SANDBOX_SESSION_ID=")
      skip "this Ruby keeps its environment apart from its process title"
    end

    assert_equal "running", @backend.status(handle)[:status]
    assert @backend.terminate(handle)

    assert_gone leader, record["child_pid"]
    assert_not workspace(sandbox).exist?
    uri = URI(result[:mcp_url])
    assert_raises(SystemCallError, "the port still answers") { http(uri) { |connection| connection.get(uri.path) } }
  ensure
    # teardown's reap goes by the marker this server wrote over.
    begin
      Process.kill("KILL", -leader) if leader && File.binread("/proc/#{leader}/cmdline").start_with?("xxxx")
    rescue SystemCallError
      # Gone, as it should be.
    end
  end

  test "a failing setup command fails the boot with its log tail and leaves nothing behind" do
    leftover = @tmp.join("leftover.pid")
    setup = [
      "echo 'first line of setup'",
      "sleep 600 & echo $! > #{leftover}; for i in $(seq 1 30); do echo noise $i; done; " \
      "echo 'leaking #{CLAUDE_CREDENTIAL}'; echo 'setup exploded'; exit 1"
    ]
    sandbox = sandbox_double(create_origin!(sandbox_yml(setup: setup)))

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }
    @pids_to_reap << Integer(leftover.read)

    assert_kind_of RuntimeError, error
    assert_match(/\ASandbox setup failed: `sleep 600 &.*` exited with status 1/, error.message)
    assert_includes error.message, "setup exploded"
    assert_includes error.message, "leaking [REDACTED]"
    assert_not_includes error.message, CLAUDE_CREDENTIAL
    assert_not_includes error.message, "first line of setup", "only the tail of the log"
    assert_gone Integer(leftover.read)
    assert_not workspace(sandbox).exist?
  end

  test "a setup command that outlives the boot timeout is stopped with its process group" do
    ActionAgent.local_sandbox_boot_timeout = 3
    leftover = @tmp.join("leftover.pid")
    setup = [ "sleep 600 & echo $! > #{leftover}; echo 'setup is hanging'; sleep 600" ]
    sandbox = sandbox_double(create_origin!(sandbox_yml(setup: setup)))

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }
    @pids_to_reap << Integer(leftover.read)

    assert_match(/\ASandbox setup failed: `sleep 600 &.*` did not finish within the boot timeout \(3s\)/, error.message)
    assert_includes error.message, "setup is hanging"
    assert_gone Integer(leftover.read)
    assert_not workspace(sandbox).exist?
  end

  test "a server that never answers fails the boot once the timeout passes" do
    ActionAgent.local_sandbox_boot_timeout = 4
    record = @tmp.join("hang.json")
    sandbox = sandbox_double(create_origin!(sandbox_yml(start: ruby_command("fake_app_server", "hang", record.to_s))))

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }

    assert_match(%r{\ASandbox server failed: the server did not answer /activeagents/mcp on port \d+ within the boot timeout \(4s\)}, error.message)
    assert_includes error.message, "fake app server: booting forever"
    pids = JSON.parse(record.read)
    @pids_to_reap.push(pids["pid"], pids["child_pid"])
    assert_gone pids["pid"], pids["child_pid"]
    assert_not workspace(sandbox).exist?
  end

  test "a server that exits during boot fails with its log" do
    sandbox = sandbox_double(create_origin!(sandbox_yml(start: "echo 'address already in use'; exit 4")))

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }

    assert_match(/\ASandbox server failed: the server exited with status 4 before it answered/, error.message)
    assert_includes error.message, "address already in use"
    assert_not workspace(sandbox).exist?
  end

  test "a manifest that is not JSON fails the boot at the manifest step" do
    sandbox = sandbox_double(create_origin!(sandbox_yml(manifest: ruby_command("fake_manifest", "garbage"))))

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }

    assert_match(/\ASandbox manifest failed: the manifest is not JSON/, error.message)
    assert_includes error.message, "fake manifest: wrote"
    assert_not workspace(sandbox).exist?
  end

  test "a malformed sandbox.yml fails the boot with a clear message" do
    sandbox = sandbox_double(create_origin!("setup:\n  bundle: install\n"))

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }

    assert_equal "Sandbox configuration failed: .activeagents/sandbox.yml is malformed: `setup` must be a list of commands",
      error.message
    assert_not workspace(sandbox).exist?
  end

  test "a checkout that cannot be fetched fails at the checkout step" do
    sandbox = sandbox_double("file://#{@tmp.join("no-such-repository")}")

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }

    assert_match(/\ASandbox checkout failed: `git fetch file:.*no-such-repository main` exited with status 128/, error.message)
    assert_not_includes error.message, GITHUB_TOKEN
    assert_not workspace(sandbox).exist?
  end

  test "the fetch authenticates with the token as a Basic header" do
    # Stands in for GitHub's smart HTTP endpoint: records each request's
    # headers and answers 404, which fails the fetch right after.
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    listener = Thread.new do
      loop do
        client = server.accept
        request = []
        while (line = client.gets) && line != "\r\n"
          request << line.chomp
        end
        requests << request
        client.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      end
    rescue IOError
      # The server closed at the end of the test.
    end
    sandbox = sandbox_double("http://127.0.0.1:#{server.addr[1]}/acme/shop.git")
    git_bin, git_argv = git_argv_recorder
    environment = Bundler.unbundled_env.merge(
      # Loopback, whatever proxy the machine running the tests uses.
      "no_proxy" => "127.0.0.1", "NO_PROXY" => "127.0.0.1",
      "PATH" => [ git_bin, Bundler.unbundled_env["PATH"] ].join(File::PATH_SEPARATOR)
    )

    error = Bundler.stub(:unbundled_env, environment) do
      assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }
    end

    request = requests.pop(timeout: 5)
    assert_match %r{\AGET /acme/shop\.git/info/refs\?service=git-upload-pack }, request.first
    assert_includes request, "Authorization: Basic #{BASIC_AUTH}"
    # ...which git got from its environment: `ps` shows every user argv.
    argv = git_argv.read
    assert_includes argv, "fetch\n", "the checkout ran the recording git"
    assert_not_includes argv, GITHUB_TOKEN, "git's argv carries the checkout token"
    assert_not_includes argv, BASIC_AUTH, "git's argv carries the checkout credentials"
    assert_match(/\ASandbox checkout failed: `git fetch http:.* main` exited with status 128/, error.message)
    assert_not_includes error.message, GITHUB_TOKEN
    assert_not_includes error.message, BASIC_AUTH
    assert_not workspace(sandbox).exist?
  ensure
    server&.close
    listener&.join(1)
  end

  test "without a sandbox.yml a checkout boots with the Rails defaults" do
    sandbox = sandbox_double(create_origin!(nil))

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }

    # The fixture has no Gemfile, so the first default command is as far as it gets.
    assert_match(/\ASandbox setup failed: `bundle install` exited with status/, error.message)

    config = Backend::Config.load(@tmp)
    assert_equal({}, config.env)
    assert_equal [ "bundle install", "bin/rails db:prepare" ], config.setup
    assert_equal "bin/rails action_agent:sandbox:manifest", config.manifest
    assert_equal "bin/rails server -b 127.0.0.1 -p $PORT", config.start
  end

  test "sandbox.yml keys are optional and unknown keys are ignored" do
    @tmp.join(".activeagents").mkpath
    @tmp.join(".activeagents/sandbox.yml").write("setup: bin/setup\nenv:\n  RAILS_ENV: development\n  WORKERS: 2\nlater: true\n")

    config = Backend::Config.load(@tmp)

    assert_equal({ "RAILS_ENV" => "development", "WORKERS" => "2" }, config.env)
    assert_equal [ "bin/setup" ], config.setup
    assert_equal "bin/rails action_agent:sandbox:manifest", config.manifest
  end

  test "the backend refuses to run anything while local sandboxes are disabled" do
    ActionAgent.local_sandboxes_enabled = false
    sandbox = sandbox_double("file://#{@tmp}")

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }
    assert_match(/Local sandboxes are disabled/, error.message)
    error = assert_raises(Backend::Error) { @backend.run_code_session(sandbox, code_session) { |_event| } }
    assert_match(/Local sandboxes are disabled/, error.message)
    assert_not ActionAgent.local_sandbox_root.exist?

    # Stopping stays possible, so turning the setting off orphans nothing.
    assert @backend.terminate("local-#{sandbox.session_id}")
  end

  test "only app_runtime sandboxes with a checkout are booted" do
    terminal = sandbox_double("file://#{@tmp}").tap { |sandbox| sandbox.sandbox_type = "terminal" }
    error = assert_raises(Backend::Error) { @backend.create_sandbox(terminal) }
    assert_match(/only boots app_runtime checkouts, not terminal sandboxes/, error.message)

    disconnected = sandbox_double("file://#{@tmp}").tap { |sandbox| sandbox.checkout_spec = nil }
    error = assert_raises(Backend::Error) { @backend.create_sandbox(disconnected) }
    assert_match(/has no checkout to boot/, error.message)
  end

  test "a code session needs the sandbox's checkout and a Claude Code connection" do
    sandbox = sandbox_double("file://#{@tmp}")

    error = assert_raises(Backend::Error) { @backend.run_code_session(sandbox, code_session) { |_event| } }
    assert_match(/has no local checkout/, error.message)

    workspace(sandbox).join("app").mkpath
    sandbox.runtime_environment = {}
    error = assert_raises(Backend::Error) { @backend.run_code_session(sandbox, code_session) { |_event| } }
    assert_match(/Connect Claude Code in Settings → Integrations/, error.message)
  end

  test "handles the backend did not issue are left alone" do
    # local-../etc names <root>/../etc: this directory, were it taken as a
    # session id.
    outside = @tmp.join("etc").tap(&:mkpath)
    assert_equal outside, ActionAgent.local_sandbox_root.join("../etc").cleanpath
    outside.join("state.json").write(JSON.generate("pid" => nil, "port" => 1))
    outside.join("passwd").write("not a sandbox's\n")

    assert @backend.terminate("local-../etc")
    assert @backend.terminate("mock-sandbox-1234")
    assert_equal({ status: "not_found", pid: nil, port: nil }, @backend.status("local-../etc"))
    assert outside.join("state.json").file?
    assert_equal "not a sandbox's\n", outside.join("passwd").read
    assert_equal 0, @backend.cleanup_expired
  end

  test "an exception raised into a boot stops the setup step it interrupted" do
    step = @tmp.join("step.pid")
    leftover = @tmp.join("leftover.pid")
    setup = [ "echo $$ > #{step}; sleep 600 & echo $! > #{leftover}; echo 'setup is hanging'; sleep 600" ]
    sandbox = sandbox_double(create_origin!(sandbox_yml(setup: setup)))
    # What a worker shutting down raises into its threads: no StandardError.
    shutdown = Class.new(Exception)
    thread = Thread.new { @backend.create_sandbox(sandbox) }
    thread.report_on_exception = false

    pids = wait_until { [ step, leftover ].map { |file| Integer(file.read.strip, exception: false) if file.exist? }.then { |all| all.all? && all } }
    @pids_to_reap.concat(pids)
    assert_equal pids.first, read_json(workspace(sandbox).join("state.json"))["step_pid"], "the running step is recorded"

    thread.raise(shutdown)

    assert_raises(shutdown) { thread.join(15) }
    assert_gone(*pids)
    assert_not workspace(sandbox).exist?
  end

  test "terminate stops a boot step recorded by a process that has since died" do
    session_id = SecureRandom.uuid
    workspace = ActionAgent.local_sandbox_root.join(session_id).tap(&:mkpath)
    leftover = @tmp.join("leftover.pid")
    # What a dashboard that crashed mid-setup leaves behind: the step's
    # process group, still running, and state.json naming it. Without the
    # session id in its environment, so only the record finds it.
    step = Process.spawn("sh", "-c", "sleep 600 & echo $! > #{leftover}; wait", pgroup: true)
    Process.detach(step)
    @pids_to_reap << -step
    child = wait_until { Integer(leftover.read.strip, exception: false) if leftover.exist? }
    starts = { step.to_s => @backend.send(:process_start, step) }
    workspace.join("state.json").write(JSON.generate("step_pid" => step, "process_starts" => starts))

    assert @backend.terminate("local-#{session_id}")

    assert_gone step, child
    assert_not workspace.exist?
  end

  test "a cancelled session that ignores SIGTERM is killed once the grace has passed" do
    sandbox = boot!
    @backend.define_singleton_method(:stop_grace) { 1 }
    session = code_session(id: 15, prompt: "SLEEP, STUBBORN")
    outcome = nil
    thread = Thread.new { outcome = @backend.run_code_session(sandbox, session) { |_event| } }
    thread.report_on_exception = false
    pids = wait_for_code_session(sandbox, "15")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # From another backend, as the controller's cancel would be.
    assert Backend.new.cancel_code_session(sandbox, session)

    assert thread.join(10), "the session outlived its cancel (claude_code_timeout is 20s)"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 8
    assert_equal 137, outcome[:exit_status], "stopped by SIGKILL"
    assert_gone pids["pid"], pids["child_pid"]
    assert_includes workspace(sandbox).join("logs/claude-15.log").read, "ignoring SIGTERM"
    state = read_json(workspace(sandbox).join("state.json"))
    assert_equal({}, state["code_sessions"])
    assert_equal({}, state["cancelling_code_sessions"])
  end

  test "a listener that took the sandbox's port is not taken for its server, nor handed the token" do
    unless File.readable?("/proc/net/tcp") || system("command -v lsof >/dev/null 2>&1")
      skip "needs /proc/net/tcp or lsof to tell who listens"
    end

    foreign, port, requests, listener = foreign_listener
    sandbox = sandbox_double(create_origin!)
    @backend.define_singleton_method(:free_port) { port }

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }

    assert_match(/\ASandbox server failed: the server exited with status \d+ before it answered on port #{port} \(another process was listening/,
      error.message)
    seen = []
    seen << requests.pop until requests.empty?
    assert seen.any?, "the probe reached the listener"
    seen.flatten.each { |line| assert_not_includes line, MCP_TOKEN, "the listener was handed the MCP token" }
    assert_not workspace(sandbox).exist?
  ensure
    foreign&.close
    listener&.join(1)
  end

  test "where nothing says who listens, only an answer as the sandbox's facade gives counts" do
    @backend.define_singleton_method(:sandbox_listener?) { |_port, _pgid, _session_id| nil }

    # The fixture refuses a ping without the manifest's token and answers one with it.
    boot!

    foreign, port, _requests, listener = foreign_listener
    @backend.define_singleton_method(:free_port) { port }
    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox_double(create_origin!)) }
    assert_match(/another process was listening/, error.message)
  ensure
    foreign&.close
    listener&.join(1)
  end

  test "a start time read from ps is the same in any time zone" do
    skip "needs ps" unless system("command -v ps >/dev/null 2>&1")

    @backend.define_singleton_method(:procfs?) { false }
    pid = Process.spawn("sleep", "30")

    here = with_env("TZ" => "America/Los_Angeles") { @backend.send(:process_start, pid) }
    there = with_env("TZ" => "Asia/Tokyo", "LC_ALL" => "de_DE.UTF-8") { @backend.send(:process_start, pid) }

    assert here.present?
    assert_equal here, there
  ensure
    if pid
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end

  test "terminate keeps a sandbox whose recorded group lives on but cannot be identified" do
    # No /proc, and no start time recorded: nothing tells the process apart
    # from one that reused its pid.
    @backend.define_singleton_method(:procfs?) { false }
    unknown = Process.spawn("sleep", "600", pgroup: true)
    session_id = SecureRandom.uuid
    workspace = ActionAgent.local_sandbox_root.join(session_id).tap(&:mkpath)
    workspace.join("state.json").write(JSON.generate("pid" => unknown, "port" => 1))
    handle = "local-#{session_id}"

    assert_equal false, @backend.terminate(handle), "the handle is kept for a retry"
    assert workspace.join("state.json").file?, "the only record of it is kept"
    assert_not process_gone?(unknown), "never signalled"
    sandbox = sandbox_double("file://#{@tmp}").tap { |double| double.session_id = session_id }
    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox) }
    assert_match(/still has processes from an earlier boot that could not be stopped/, error.message)

    Process.kill("KILL", unknown)
    Process.wait(unknown)
    unknown = nil
    assert @backend.terminate(handle), "once it is gone, the workspace goes too"
    assert_not workspace.exist?
  ensure
    if unknown
      Process.kill("KILL", unknown)
      Process.wait(unknown)
    end
  end

  test "terminate spares a live process whose start time does not match the one recorded" do
    stranger = Process.spawn("sleep", "600", pgroup: true)
    # Reaped as soon as it exits: without /proc, kill(0) cannot tell a
    # zombie from a live process.
    reaper = Process.detach(stranger)
    [ true, false ].each do |procfs|
      @backend.define_singleton_method(:procfs?) { false } unless procfs
      skip "needs ps" unless procfs || system("command -v ps >/dev/null 2>&1")

      recorded = @backend.send(:process_start, stranger)
      mismatch = recorded.is_a?(Integer) ? recorded + 1 : "Thu Jan  1 00:00:00 1970"
      workspace = ActionAgent.local_sandbox_root.join(SecureRandom.uuid).tap(&:mkpath)
      workspace.join("state.json").write(JSON.generate("pid" => stranger, "process_starts" => { stranger.to_s => mismatch }))

      assert @backend.terminate("local-#{workspace.basename}")

      assert_not workspace.exist?
      assert_not process_gone?(stranger), "an unrelated process was signalled (procfs: #{procfs})"
    end

    # The same record with its true start time does stop it.
    workspace = ActionAgent.local_sandbox_root.join(SecureRandom.uuid).tap(&:mkpath)
    starts = { stranger.to_s => @backend.send(:process_start, stranger) }
    workspace.join("state.json").write(JSON.generate("pid" => stranger, "process_starts" => starts))
    assert @backend.terminate("local-#{workspace.basename}")
    assert reaper.join(5), "the recorded process was not stopped"
  ensure
    begin
      Process.kill("KILL", stranger) if stranger
    rescue SystemCallError
      # Stopped by the test, as it should be.
    end
  end

  test "state.json is replaced whole, never left half written" do
    workspace = ActionAgent.local_sandbox_root.join(SecureRandom.uuid).tap(&:mkpath)
    @backend.send(:update_state, workspace) { |state| state["pid"] = 1234 }
    first = workspace.join("state.json").stat.ino

    # JSON cannot write NaN: the update fails after the state was changed.
    assert_raises(JSON::GeneratorError) do
      @backend.send(:update_state, workspace) do |state|
        state["pid"] = 99
        state["bad"] = Float::NAN
      end
    end

    assert_equal({ "pid" => 1234 }, JSON.parse(workspace.join("state.json").read), "the last good state is kept")
    @backend.send(:update_state, workspace) { |state| state["port"] = 1 }
    assert_equal({ "pid" => 1234, "port" => 1 }, JSON.parse(workspace.join("state.json").read))
    assert_not_equal first, workspace.join("state.json").stat.ino, "replaced by a rename, not rewritten in place"
    assert_equal 0o600, workspace.join("state.json").stat.mode & 0o777
    assert_equal %w[state.json state.lock], workspace.children.map { |child| child.basename.to_s }.sort, "no temporary file is left"

    other = ActionAgent.local_sandbox_root.join(SecureRandom.uuid).tap(&:mkpath)
    assert_raises(Errno::ENOENT) { @backend.send(:update_state, other, create: false) { |state| state["x"] = 1 } }
    assert_not other.join("state.json").exist?
  end

  test "terminate also stops a process that left the sandbox's process group" do
    skip "needs /proc to find it" unless File.exist?("/proc/self/environ")
    skip "needs setsid" unless system("command -v setsid >/dev/null 2>&1")

    escaped = @tmp.join("escaped.pid")
    start = "setsid sh -c 'echo $$ > #{escaped}; exec sleep 600' & exec #{ruby_command("fake_app_server")}"
    sandbox = sandbox_double(create_origin!(sandbox_yml(start: start)))
    @backend.create_sandbox(sandbox)
    record = server_record(workspace(sandbox))
    pid = wait_until { Integer(escaped.read.strip, exception: false) if escaped.exist? }
    @pids_to_reap << pid
    wait_until { File.exist?("/proc/#{pid}") && File.binread("/proc/#{pid}/environ").include?("ACTION_AGENT_SANDBOX_SESSION_ID=") }
    assert_not_equal record["pgid"], Process.getpgid(pid), "it left the server's group"

    assert @backend.terminate("local-#{sandbox.session_id}")

    assert_gone record["pid"], pid
  end

  test "a server that starts outside the sandbox's process group is known by its session id, and stopped" do
    skip "needs /proc to find it" unless File.exist?("/proc/self/environ")
    skip "needs setsid" unless system("command -v setsid >/dev/null 2>&1")

    # The shell `start` runs stays in the recorded group; the server it
    # starts leads a session of its own, as a daemonizing server would.
    start = "setsid #{ruby_command("fake_app_server")} & wait"
    sandbox = sandbox_double(create_origin!(sandbox_yml(start: start)))
    result = @backend.create_sandbox(sandbox)
    record = server_record(workspace(sandbox))
    assert_not_equal read_json(workspace(sandbox).join("state.json"))["pid"], record["pgid"]
    uri = URI(result[:mcp_url])
    assert_equal "200", rpc(uri, token: MCP_TOKEN).code

    assert @backend.terminate("local-#{sandbox.session_id}")

    assert_gone record["pid"], record["child_pid"]
  end

  test "local sandboxes are off by default outside development and test" do
    ActionAgent.local_sandboxes_enabled = nil

    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      assert_equal false, ActionAgent.local_sandboxes_enabled?
      error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox_double("file://#{@tmp}")) }
      assert_match(/Local sandboxes are disabled/, error.message)
    end
    assert_not ActionAgent.local_sandbox_root.exist?
    assert ActionAgent.local_sandboxes_enabled?, "on by default in test"
  end

  test "a filesystem monitor or hooks set in the checkout's git config never run" do
    sandbox = boot!
    app = workspace(sandbox).join("app")
    monitor = @tmp.join("fsmonitor-ran")
    hook = @tmp.join("hook-ran")
    hooks = @tmp.join("hooks").tap(&:mkpath)
    # `git add` writes the index, which runs post-index-change.
    hooks.join("post-index-change").write("#!/bin/sh\ntouch #{hook}\n")
    hooks.join("post-index-change").chmod(0o755)
    # What a session steered by the repository's content could write.
    system("git", "-C", app.to_s, "config", "core.fsmonitor", "touch #{monitor}; false", exception: true)
    system("git", "-C", app.to_s, "config", "core.hooksPath", hooks.to_s, exception: true)

    outcome = @backend.run_code_session(sandbox, code_session) { |_event| }

    assert_includes outcome[:diff], "+Edited by the fake Claude Code."
    assert_not monitor.exist?, "the fsmonitor command ran"
    assert_not hook.exist?, "the checkout's hook ran"
  end

  test "terminate kills a server that ignores SIGTERM" do
    @backend.define_singleton_method(:stop_grace) { 1 }
    sandbox = sandbox_double(create_origin!(sandbox_yml(start: ruby_command("fake_app_server", "stubborn"))))
    @backend.create_sandbox(sandbox)
    record = server_record(workspace(sandbox))

    assert @backend.terminate("local-#{sandbox.session_id}")

    assert_gone record["pid"], record["child_pid"]
    assert_not workspace(sandbox).exist?
  end

  test "a booted workspace is readable by its owner alone" do
    sandbox = boot!
    workspace = workspace(sandbox)

    { "." => 0o700, "logs" => 0o700, "claude" => 0o700, "state.json" => 0o600, "runtime.json" => 0o600 }.each do |path, mode|
      assert_equal format("%o", mode), format("%o", workspace.join(path).stat.mode & 0o777), path
    end
  end

  test "the configured permission mode reaches Claude Code" do
    ActionAgent.claude_code_permission_mode = "plan"
    sandbox = boot!

    @backend.run_code_session(sandbox, code_session) { |_event| }

    argv = JSON.parse(workspace(sandbox).join("claude/invocation.json").read)["argv"]
    assert_equal "plan", argv[argv.index("--permission-mode") + 1]
  end

  test "the backend refuses a model name that reads as an option" do
    sandbox = sandbox_double("file://#{@tmp}")
    workspace(sandbox).join("app").mkpath

    [ "--dangerously-skip-permissions", "-p", "sonnet --verbose" ].each do |model|
      error = assert_raises(Backend::Error) { @backend.run_code_session(sandbox, code_session(model: model)) { |_event| } }
      assert_equal "#{model.inspect} is not a model name", error.message
    end
    assert_not workspace(sandbox).join("claude/invocation.json").exist?, "Claude Code never ran"
  end

  test "a checkout whose git config defines a filter driver is not diffed" do
    sandbox = boot!
    app = workspace(sandbox).join("app")
    marker = @tmp.join("filter-ran")
    # What a session steered by the repository's content could write: a
    # clean filter runs its command on `git add` and `git diff`.
    system("git", "-C", app.to_s, "config", "filter.x.clean", "touch #{marker}; cat", exception: true)
    File.write(app.join(".gitattributes"), "* filter=x\n")

    outcome = @backend.run_code_session(sandbox, code_session) { |_event| }

    assert_match(/diff not recorded/, outcome[:diff])
    assert_not File.exist?(marker), "the filter's command never ran"
  end

  private

  # A listener on a free port, as another process could bind the port the
  # backend picked: 405 to anything, each request's head recorded.
  def foreign_listener
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    listener = Thread.new do
      loop do
        client = server.accept
        request = []
        while (line = client.gets) && line != "\r\n"
          request << line.chomp
        end
        requests << request
        client.write("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      end
    rescue IOError
      # Closed at the end of the test.
    end
    [ server, server.addr[1], requests, listener ]
  end

  def boot!
    sandbox_double(create_origin!).tap { |sandbox| @backend.create_sandbox(sandbox) }
  end

  def sandbox_double(clone_url)
    SandboxDouble.new(
      session_id: SecureRandom.uuid,
      sandbox_type: "app_runtime",
      checkout_spec: {
        repository: "acme/shop", ref: "main", clone_url: clone_url, username: "x-access-token", token: GITHUB_TOKEN
      },
      runtime_environment: { "CLAUDE_CODE_OAUTH_TOKEN" => CLAUDE_CREDENTIAL }
    )
  end

  def code_session(id: 7, prompt: "Say hello", model: nil)
    CodeSessionDouble.new(id: id, prompt: prompt, model: model)
  end

  def workspace(sandbox)
    ActionAgent.local_sandbox_root.join(sandbox.session_id)
  end

  def sandbox_yml(setup: [ "mkdir -p tmp && env > tmp/setup_env.txt" ], manifest: ruby_command("fake_manifest"),
    start: ruby_command("fake_app_server"))
    {
      "env" => { "FIXTURE_FLAVOR" => "local" },
      "setup" => setup,
      "manifest" => manifest,
      "start" => start,
      "a_key_from_the_future" => "is ignored"
    }.to_yaml
  end

  # A git repository to clone, with a README for Claude Code to edit, a file
  # for it to delete, and tmp/ ignored as a Rails app ignores it.
  # +sandbox_yml+ nil commits none.
  def create_origin!(sandbox_yml = self.sandbox_yml)
    origin = @tmp.join("origin-#{SecureRandom.hex(4)}")
    origin.join(".activeagents").mkpath
    origin.join("README.md").write("# Fixture app\n")
    origin.join("OBSOLETE.md").write("Nothing needs this file.\n")
    origin.join(".gitignore").write("tmp/\n")
    origin.join(".activeagents/sandbox.yml").write(sandbox_yml) if sandbox_yml

    git(origin, "init", "-q", "-b", "main")
    git(origin, "add", "-A")
    git(origin, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false",
      "commit", "-q", "-m", "Fixture app")
    "file://#{origin}"
  end

  def git(dir, *args)
    system("git", "-C", dir.to_s, *args, out: File::NULL, err: File::NULL, exception: true)
  end

  def ruby_command(script, *args)
    [ RbConfig.ruby, File.join(FIXTURES, "#{script}.rb"), *args ].shelljoin
  end

  # The fake CLI behind a wrapper in the test's tmpdir: the exact Ruby running
  # the tests, whatever the fixture's executable bit or PATH say.
  def fake_claude_command(legacy: false)
    wrapper = @tmp.join(legacy ? "claude-legacy" : "claude")
    arguments = [ RbConfig.ruby, File.join(FIXTURES, "fake_claude.rb"), *("--legacy-cli" if legacy) ].shelljoin
    wrapper.write("#!/bin/sh\nexec #{arguments} \"$@\"\n")
    wrapper.chmod(0o755)
    wrapper.to_s
  end

  # SIGKILL to a process (or, negative, a group) a test started, but only
  # while it is still one of this suite's sandbox processes: its pid may have
  # been reused since.
  def reap(pid)
    if File.exist?("/proc/self/environ")
      return unless File.binread("/proc/#{pid.abs}/environ").include?("ACTION_AGENT_SANDBOX_SESSION_ID=")
    end

    Process.kill("KILL", pid)
  rescue SystemCallError
    # Already gone.
  end

  # The server's process group as state.json recorded it, negated for
  # Process.kill.
  def recorded_server_group(workspace)
    pid = JSON.parse(workspace.join("state.json").read)["pid"]
    -pid if pid.is_a?(Integer) && pid > 1
  rescue SystemCallError, JSON::ParserError
    nil
  end

  def server_record(workspace)
    JSON.parse(workspace.join("app/tmp/server.json").read).tap do |record|
      @pids_to_reap.push(record["pid"], record["child_pid"])
    end
  end

  # Waits for a running session's fake CLI to report its pids, and for the
  # backend to have recorded the session.
  def wait_for_code_session(sandbox, id)
    pids_file = workspace(sandbox).join("claude/pids.json")
    wait_until { pids_file.exist? && JSON.parse(workspace(sandbox).join("state.json").read).dig("code_sessions", id) }
    JSON.parse(pids_file.read).tap { |pids| @pids_to_reap.push(pids["pid"], pids["child_pid"]) }
  rescue JSON::ParserError
    retry
  end

  # Runs the block with the pid of each Claude Code process +backend+
  # spawns, before the backend goes on to record it.
  def after_spawn(backend, &block)
    hook = Module.new do
      define_method(:spawn_group) do |env, *argv, **options|
        super(env, *argv, **options).tap { |pid| block.call(pid) if argv.include?("-p") }
      end
      private :spawn_group
    end
    backend.singleton_class.prepend(hook)
  end

  # A `git` first on PATH that appends each argument it is given to a file,
  # then runs the real one.
  def git_argv_recorder
    real = ENV["PATH"].split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "git") }.find { |path| File.executable?(path) }
    bin = @tmp.join("git-recorder").tap(&:mkpath)
    log = @tmp.join("git-argv.log").tap { |file| file.write("") }
    bin.join("git").write(<<~SH)
      #!/bin/sh
      for arg in "$@"; do printf '%s\\n' "$arg"; done >> #{log.to_s.shellescape}
      exec #{real.shellescape} "$@"
    SH
    bin.join("git").chmod(0o755)
    [ bin.to_s, log ]
  end

  # The live processes started for +sandbox+, found by the session id every
  # one of them carries in its environment.
  def sandbox_processes(sandbox)
    marker = "ACTION_AGENT_SANDBOX_SESSION_ID=#{sandbox.session_id}"
    Dir.children("/proc").grep(/\A\d+\z/).map(&:to_i).select do |pid|
      File.binread("/proc/#{pid}/environ").split("\0").include?(marker) && !process_gone?(pid)
    rescue SystemCallError
      false
    end
  end

  def read_json(path)
    JSON.parse(path.read)
  rescue JSON::ParserError, SystemCallError
    {}
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (value = yield)
      flunk "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    value
  end

  def assert_gone(*pids)
    pids.each do |pid|
      wait_until(timeout: 5) { process_gone?(pid) }
    rescue Minitest::Assertion
      flunk "process #{pid} is still running"
    end
  end

  # Gone, or a zombie: an init that does not reap (a container's) keeps
  # orphaned zombies around, and they run nothing.
  def process_gone?(pid)
    if File.exist?("/proc/self/stat")
      stat = File.read("/proc/#{pid}/stat")
      %w[Z X].include?(stat[(stat.rindex(")") + 2)..].split.first)
    else
      Process.kill(0, pid)
      false
    end
  rescue Errno::ENOENT, Errno::ESRCH
    true
  end

  def with_env(values)
    saved = values.keys.index_with { |name| ENV[name] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  def http(uri, &block)
    Net::HTTP.new(uri.host, uri.port, nil).start(&block)
  end

  def rpc(uri, token:)
    request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream")
    request["Authorization"] = "Bearer #{token}" if token
    request.body = JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list")
    http(uri) { |connection| connection.request(request) }
  end
end
