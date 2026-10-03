# frozen_string_literal: true

require "test_helper"

# Boot specs on the :local backend: a throwaway git repository holding a
# Rails app's skeleton (a Gemfile.lock, config/application.rb, a bin/rails
# that runs fake_rails.rb) is cloned over file://, and booted with a fake
# `bundle` first on PATH. Real processes, ports and logs; the fakes record
# every command they were given to a file outside the workspace.
class LocalSandboxBootstrapTest < ActiveSupport::TestCase
  Backend = ActionAgent::LocalSandboxBackend
  Spec = ActionAgent::SandboxBootSpec

  FIXTURES = File.expand_path("support/local_sandbox", __dir__)
  GITHUB_TOKEN = "ghs_fixtureBootstrapToken0123456789abcd"
  CLAUDE_CREDENTIAL = "sk-ant-api03-fixtureBootstrap-0123456789"
  SECRET = "fixture-project-secret-0123456789"
  MCP_TOKEN = "fixture-mcp-token-0123456789"
  ENGINE = {
    "activeagent" => { "source" => "rubygems", "version" => "1.9.0" },
    "actionagent" => { "source" => "rubygems", "version" => "1.9.0" }
  }.freeze

  SandboxDouble = Struct.new(:session_id, :sandbox_type, :checkout_spec, :runtime_environment, keyword_init: true) do
    def app_runtime?
      sandbox_type == "app_runtime"
    end
  end

  def setup
    super
    @tmp = Pathname(Dir.mktmpdir("local-sandbox-bootstrap")).realpath
    @saved = {
      local_sandboxes_enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled),
      local_sandbox_root: ActionAgent.instance_variable_get(:@local_sandbox_root),
      local_sandbox_boot_timeout: ActionAgent.local_sandbox_boot_timeout
    }
    ActionAgent.local_sandboxes_enabled = true
    ActionAgent.local_sandbox_root = @tmp.join("sandboxes").to_s
    ActionAgent.local_sandbox_boot_timeout = 20

    config = WebMock::Config.instance
    @webmock = [ config.allow_net_connect, config.allow_localhost, config.allow, config.net_http_connect_on_start ]
    VCR.turn_off!
    WebMock.disable_net_connect!(allow_localhost: true)

    @tools_log = @tmp.join("tools.log").tap { |file| file.write("") }
    @control = @tmp.join("control.json").tap { |file| file.write("{}") }
    @bin = @tmp.join("fake-bin").tap(&:mkpath)
    @bin.join("bundle").write("#!/bin/sh\nexec #{[ RbConfig.ruby, File.join(FIXTURES, "fake_bundle.rb") ].shelljoin} \"$@\"\n")
    @bin.join("bundle").chmod(0o755)
    @backend = Backend.new
  end

  def teardown
    with_fake_tools do
      root = ActionAgent.local_sandbox_root
      root.children.each { |dir| Backend.new.terminate("local-#{dir.basename}") } if root.directory?
    end
    @saved.each { |name, value| ActionAgent.public_send("#{name}=", value) }
    VCR.turn_on!
    config = WebMock::Config.instance
    config.allow_net_connect, config.allow_localhost, config.allow, config.net_http_connect_on_start = @webmock
    FileUtils.rm_rf(@tmp)
    super
  end

  test "a Rails app with neither gem boots to ready with the bootstrap spec, and its facade answers" do
    sandbox = sandbox_double(rails_origin!)

    result = with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE).to_h) }

    uri = URI(result[:mcp_url])
    assert_equal "local-#{sandbox.session_id}", result[:container_name]
    assert_equal MCP_TOKEN, result[:mcp_token]
    response = rpc(uri, token: MCP_TOKEN)
    assert_equal "200", response.code
    assert_equal "fixture_tool", JSON.parse(response.body).dig("result", "tools", 0, "name")

    assert_equal [
      "bundle config set --local frozen false",
      "bundle install",
      "bundle add actionagent --version ~> 1.9.0",
      "rails generate active_agent:install --skip",
      "rails generate action_agent:install --skip",
      "rails -T -A",
      "rails db:prepare",
      "rails action_agent:sandbox:manifest",
      "rails server -b 127.0.0.1 -p #{uri.port}"
    ], tool_calls

    status = @backend.boot_status(sandbox)
    assert_equal "spec", status[:mode]
    assert_equal "bootstrap", status[:kind]
    assert_nil status[:failed_step]
    assert_equal({
      "checkout" => "succeeded", "preflight" => "succeeded", "bundle_config" => "succeeded", "bundle_install" => "succeeded",
      "add_engine" => "succeeded", "install_framework" => "succeeded", "install_engine" => "succeeded",
      "javascript_build" => "skipped", "css_build" => "skipped", "tailwindcss_build" => "skipped",
      "db_prepare" => "succeeded", "manifest" => "succeeded", "start" => "succeeded"
    }, status[:steps].to_h { |step| [ step[:name], step[:status] ] })
    assert_equal "the app defines no javascript:build task", status[:steps].find { |step| step[:name] == "javascript_build" }[:detail]
    assert status[:steps].all? { |step| step[:duration_ms].is_a?(Integer) }

    logs = workspace(sandbox).join("logs").children.map { |log| log.basename.to_s }.sort
    assert_equal %w[
      add_engine.log bundle_config.log bundle_install.log checkout.log css_build.log db_prepare.log install_engine.log
      install_framework.log javascript_build.log manifest.log preflight.log server.log tailwindcss_build.log
    ], logs, "each step writes a log of its own"
    assert_includes workspace(sandbox).join("logs/add_engine.log").read, "fake bundle: added actionagent"
  end

  test "chosen schema tools are written after db_prepare, and the manifest's models reach the result" do
    sandbox = sandbox_double(rails_origin!)
    models = [ { "name" => "Reservation", "table" => "reservations", "columns" => [ { "name" => "status", "type" => "string" } ] } ]
    control("models" => models)
    step = Spec.schema_tools_step([ { "model" => "Reservation", "filterable" => [ "status" ], "returns" => %w[status starts_at] } ])

    result = with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE, steps: [ step ]).to_h) }

    calls = tool_calls
    assert_operator calls.index("rails db:prepare"),
      :<, calls.index("rails generate active_agent:schema_tools Reservation --force --filterable status --returns status starts_at")
    tools = workspace(sandbox).join("app/app/agent_tools/reservation_tools.rb").read
    assert_includes tools, "filterable :id, :status\n"
    assert_includes tools, "returns :id, :status, :starts_at\n"
    assert_equal models, result[:app_models]
    assert_equal "succeeded", @backend.boot_status(sandbox)[:steps].find { |entry| entry[:name] == "schema_tools" }[:status]
  end

  test "the checkout holds only what the generators, bundle add and db:prepare wrote" do
    sandbox = sandbox_double(rails_origin!)

    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE).to_h) }

    app = workspace(sandbox).join("app")
    changed = git_output(app, "status", "--porcelain", "--untracked-files=all").lines.map { |line| line[3..].strip }.sort
    assert_equal %w[
      Gemfile Gemfile.lock app/agents/application_agent.rb config/active_agent.yml config/initializers/action_agent.rb
      config/routes.rb db/migrate/20260101000000_create_active_agent_dashboard_tables.rb db/schema.rb
    ], changed
    assert_includes app.join("Gemfile").read, %(gem "actionagent", "~> 1.9.0")
    assert_includes app.join("Gemfile.lock").read, "    actionagent (1.9.0)"
  end

  test "the engine comes from where the dashboard bundles it, here this repository's path" do
    sandbox = sandbox_double(rails_origin!)
    engine = Spec.engine_gems

    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap.to_h) }

    gemfile = workspace(sandbox).join("app/Gemfile").read
    assert_includes gemfile, %(gem "activeagent", path: #{engine.dig("activeagent", "path").inspect})
    assert_includes gemfile, %(gem "actionagent", path: #{engine.dig("actionagent", "path").inspect})
    assert_includes tool_calls, "bundle add activeagent --path #{engine.dig("activeagent", "path")} --skip-install"
  end

  test "a checkout that already bundles activeagent keeps its config and application agent byte for byte" do
    config = "development:\n  anthropic:\n    service: Anthropic # ours\n"
    application_agent = "class ApplicationAgent < ActiveAgent::Base\n  generate_with :anthropic # ours\nend\n"
    sandbox = sandbox_double(rails_origin!(gems: [ "activeagent (1.8.0)" ],
      files: { "config/active_agent.yml" => config, "app/agents/application_agent.rb" => application_agent }))

    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE).to_h) }

    app = workspace(sandbox).join("app")
    assert_equal config, app.join("config/active_agent.yml").read
    assert_equal application_agent, app.join("app/agents/application_agent.rb").read
    assert_not_includes tool_calls, "rails generate active_agent:install --skip"
    step = @backend.boot_status(sandbox)[:steps].find { |entry| entry[:name] == "install_framework" }
    assert_equal [ "skipped", "the checkout already locks activeagent" ], step.values_at(:status, :detail)
  end

  test "asset build steps run only for the tasks the app defines" do
    control("tasks" => [ "javascript:build", "tailwindcss:build" ])
    sandbox = sandbox_double(rails_origin!)

    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE).to_h) }

    assert_includes tool_calls, "rails javascript:build"
    assert_includes tool_calls, "rails tailwindcss:build"
    assert_not_includes tool_calls, "rails css:build"
    assert_equal 1, tool_calls.count("rails -T -A"), "the tasks are listed once per boot"
  end

  test "preflight refuses an app the engine cannot run, before any of its commands" do
    lock_without_rails = rails_lock.sub("    railties (8.0.1)\n", "")
    {
      { lock: nil } => "acme/shop has no Gemfile.lock at its root: a bootstrap boot needs a bundled Rails app",
      { ruby: "3.1.4p223" } => "acme/shop needs Ruby 3.1.4 (Gemfile.lock); the engine needs Ruby 3.2 or later",
      { railties: "7.1.3" } => "acme/shop locks railties 7.1.3; the engine needs Rails 7.2 or later",
      { lock: lock_without_rails } => "acme/shop's Gemfile.lock locks no railties: a bootstrap boot needs a Rails app",
      { application: false } => "acme/shop has no config/application.rb at its root: a bootstrap boot needs the Rails app at the " \
        "repository root"
    }.each do |fixture, reason|
      sandbox = sandbox_double(rails_origin!(**fixture))

      error = assert_raises(Backend::Error, reason) do
        with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE, keep_on_failure: true).to_h) }
      end

      assert_match(/\ASandbox preflight failed: #{Regexp.escape(reason)}/, error.message)
      assert_empty tool_calls, "#{reason}: nothing of the checkout's ran"
      assert_not workspace(sandbox).exist?, "#{reason}: a refused checkout is not kept"
    end
  end

  test "a .ruby-version too old is refused when the lock pins no Ruby" do
    sandbox = sandbox_double(rails_origin!(ruby: nil, files: { ".ruby-version" => "ruby-3.1.2\n" }))

    error = assert_raises(Backend::Error) do
      with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE).to_h) }
    end

    assert_match(/acme\/shop needs Ruby 3\.1\.2 \(\.ruby-version\); the engine needs Ruby 3\.2 or later/, error.message)
  end

  test "a start URL that answers 500 fails the start step with the status and the server's log tail" do
    control("root_status" => 500, "tasks" => [])
    sandbox = sandbox_double(rails_origin!)

    error = assert_raises(Backend::Error) do
      with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE, keep_on_failure: true).to_h) }
    end

    assert_match(/\ASandbox start failed: GET \/ answered 500/, error.message)
    assert_includes error.message, "--- last lines of logs/server.log ---"
    assert_includes error.message, "fake app server: listening"
    assert_equal "start", @backend.boot_status(sandbox)[:failed_step]
  end

  test "a start URL other than / is probed instead" do
    control("root_status" => 500)
    sandbox = sandbox_double(rails_origin!)

    result = with_fake_tools do
      @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE, start_url: "/up").to_h)
    end

    assert result[:mcp_url].present?, "/up answers 404, which is not a server error"
  end

  test "a step that outlives its own timeout fails naming the step and the limit" do
    control("sleep" => [ "db:prepare" ])
    spec = Spec.bootstrap(engine: ENGINE).to_h
    spec["steps"].find { |step| step["name"] == "db_prepare" }["timeout"] = 2
    sandbox = sandbox_double(rails_origin!)

    error = assert_raises(Backend::Error) { with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec) } }

    assert_match(/\ASandbox db_prepare failed: `bin\/rails db:prepare` did not finish within its 2s timeout/, error.message)
    assert_includes error.message, "fake rails: db:prepare is hanging"
    assert_not workspace(sandbox).exist?, "without keep_on_failure a failed boot cleans up as before"
  end

  test "the boot's own timeout bounds the steps together" do
    control("sleep" => [ "db:prepare" ])
    spec = Spec.bootstrap(engine: ENGINE).to_h.merge("kind" => "custom", "timeout" => 4)
    sandbox = sandbox_double(rails_origin!)

    error = assert_raises(Backend::Error) { with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec) } }

    assert_match(/\ASandbox db_prepare failed: `bin\/rails db:prepare` did not finish within the boot timeout \(4s\)/, error.message)
  end

  test "a spec for checkouts without the engine bounds the boot only where it applies" do
    control("sleep" => [ "db:prepare" ])
    ActionAgent.local_sandbox_boot_timeout = 3
    spec = Spec.bootstrap(engine: ENGINE, apply: "without_engine").to_h.merge("kind" => "custom", "timeout" => 5)

    bundled = sandbox_double(rails_origin!(gems: [ "actionagent (1.8.1)", "activeagent (1.8.1)" ]))
    error = assert_raises(Backend::Error) { with_fake_tools { @backend.create_sandbox(bundled, boot_config: spec) } }
    assert_match(/\ASandbox setup failed: `bin\/rails db:prepare` did not finish within the boot timeout \(3s\)/, error.message)

    bare = sandbox_double(rails_origin!)
    error = assert_raises(Backend::Error) { with_fake_tools { @backend.create_sandbox(bare, boot_config: spec) } }
    assert_match(/\ASandbox db_prepare failed: `bin\/rails db:prepare` did not finish within the boot timeout \(5s\)/, error.message)
  end

  # Waiting out a bootstrap's limit takes half an hour, so these read the
  # limit each boot ran under rather than run into it.
  test "a bootstrap gets the longer of its own limit and the configured boot limit" do
    with_fake_tools { @backend.create_sandbox(sandbox_double(rails_origin!), boot_config: Spec.bootstrap(engine: ENGINE).to_h) }
    assert_equal 1800, @backend.instance_variable_get(:@boot_timeout), "the configured 20s is less than a bootstrap needs"

    ActionAgent.local_sandbox_boot_timeout = 3600
    without_engine = Spec.bootstrap(engine: ENGINE, apply: "without_engine").to_h
    with_fake_tools { @backend.create_sandbox(sandbox_double(rails_origin!), boot_config: without_engine) }
    assert_equal 3600, @backend.instance_variable_get(:@boot_timeout), "once a spec for checkouts without the engine applies"

    control("fail" => [ "db:prepare" ])
    kept = sandbox_double(rails_origin!)
    assert_raises(Backend::Error) do
      with_fake_tools { @backend.create_sandbox(kept, boot_config: Spec.bootstrap(engine: ENGINE, keep_on_failure: true).to_h) }
    end
    assert_equal 3600, @backend.instance_variable_get(:@boot_timeout)
    control({})
    resumer = Backend.new
    with_fake_tools { resumer.resume_boot(kept, from: nil) }
    assert_equal 3600, resumer.instance_variable_get(:@boot_timeout), "a resume"
  end

  test "a kept boot resumes from the step that failed, without cloning or re-running what came before" do
    control("fail" => [ "db:prepare" ])
    sandbox = sandbox_double(rails_origin!)
    spec = Spec.bootstrap(engine: ENGINE, keep_on_failure: true)

    error = assert_raises(Backend::Error) { with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec.to_h) } }

    assert_match(/\ASandbox db_prepare failed: `bin\/rails db:prepare` exited with status 1/, error.message)
    state = JSON.parse(workspace(sandbox).join("state.json").read)
    assert_equal "db_prepare", state.dig("boot", "failed_step")
    assert state.dig("boot", "kept")
    assert workspace(sandbox).join("app/config/initializers/action_agent.rb").file?, "the workspace is kept"
    assert_equal "stopped", @backend.status("local-#{sandbox.session_id}")[:status]

    control({})
    @tools_log.write("")
    checkout_log = workspace(sandbox).join("logs/checkout.log").read
    result = with_fake_tools { Backend.new.resume_boot(sandbox, from: nil) }

    assert_equal "200", rpc(URI(result[:mcp_url]), token: MCP_TOKEN).code
    port = URI(result[:mcp_url]).port
    assert_equal [ "rails db:prepare", "rails action_agent:sandbox:manifest", "rails server -b 127.0.0.1 -p #{port}" ], tool_calls
    assert_equal checkout_log, workspace(sandbox).join("logs/checkout.log").read, "nothing was cloned again"
    status = @backend.boot_status(sandbox)
    assert_nil status[:failed_step]
    assert_not status[:kept]
    assert_equal "succeeded", status[:steps].find { |step| step[:name] == "install_engine" }[:status]
    assert_equal %w[succeeded succeeded], status[:steps].last(2).map { |step| step[:status] }

    assert @backend.terminate("local-#{sandbox.session_id}")
    assert_not workspace(sandbox).exist?
  end

  test "a resume can start from a named step, and refuses one the boot does not have" do
    control("fail" => [ "db:prepare" ])
    sandbox = sandbox_double(rails_origin!)
    spec = Spec.bootstrap(engine: ENGINE, keep_on_failure: true)
    assert_raises(Backend::Error) { with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec.to_h) } }

    assert_equal %w[
      bundle_config bundle_install add_engine install_framework install_engine javascript_build css_build tailwindcss_build
      db_prepare manifest start
    ], @backend.boot_status(sandbox)[:resumable_steps], "the checkout and preflight are not the plan's to re-run"
    error = assert_raises(Backend::Error) { with_fake_tools { Backend.new.resume_boot(sandbox, from: "checkout") } }
    assert_match(/"checkout" is not a step this boot can resume from \(bundle_config, bundle_install, add_engine/, error.message)
    assert JSON.parse(workspace(sandbox).join("state.json").read).dig("boot", "kept"), "a refused resume keeps the boot"

    control({})
    @tools_log.write("")
    with_fake_tools { Backend.new.resume_boot(sandbox, from: "install_engine") }

    assert_equal "rails generate action_agent:install --skip", tool_calls.first
  end

  test "a resumed boot that fails again is kept again, and only one resume runs at a time" do
    control("fail" => [ "db:prepare" ])
    sandbox = sandbox_double(rails_origin!)
    spec = Spec.bootstrap(engine: ENGINE, keep_on_failure: true)
    assert_raises(Backend::Error) { with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec.to_h) } }

    assert_raises(Backend::Error) { with_fake_tools { Backend.new.resume_boot(sandbox, from: nil) } }

    state = JSON.parse(workspace(sandbox).join("state.json").read)
    assert state.dig("boot", "kept")
    assert_equal "db_prepare", state.dig("boot", "failed_step")

    @backend.send(:claim_kept_boot, workspace(sandbox))
    error = assert_raises(Backend::Error) { with_fake_tools { Backend.new.resume_boot(sandbox, from: nil) } }
    assert_match(/has no failed boot kept to resume/, error.message)
  end

  test "a boot that was not kept cannot be resumed" do
    sandbox = sandbox_double(rails_origin!)

    error = assert_raises(Backend::Error) { Backend.new.resume_boot(sandbox, from: nil) }

    assert_match(/has no failed boot kept to resume: start it again/, error.message)
  end

  test "secrets from the spec reach the steps, and appear in no log, error or recorded state" do
    control("echo" => "STRIPE_KEY", "fail" => [ "db:prepare" ])
    sandbox = sandbox_double(rails_origin!)
    spec = Spec.bootstrap(engine: ENGINE, keep_on_failure: true, secrets: { "STRIPE_KEY" => SECRET })

    error = assert_raises(Backend::Error) { with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec.to_h) } }

    assert_includes error.message, "fake rails: db:prepare sees [REDACTED]", "the step had the value, and its output is masked"
    assert_not_includes error.message, SECRET
    workspace(sandbox).glob("{logs/*,state.json,runtime.json}").each do |file|
      assert_not_includes file.read, SECRET, "#{file} carries the secret"
    end
    assert_equal [ "STRIPE_KEY" ], JSON.parse(workspace(sandbox).join("state.json").read).dig("boot", "spec", "secret_names")
    assert_not_includes @backend.boot_log(sandbox, step: "db_prepare")[:text], SECRET

    # The recorded spec has no secret values, so a resume needs the spec.
    error = assert_raises(Backend::Error) { Backend.new.resume_boot(sandbox, from: nil) }
    assert_match(/needs its boot spec again: the values of STRIPE_KEY are never kept/, error.message)

    control("echo" => "STRIPE_KEY")
    with_fake_tools { Backend.new.resume_boot(sandbox, from: nil, boot_config: spec.to_h) }
    assert_includes workspace(sandbox).join("logs/db_prepare.log").read, "db:prepare sees [REDACTED]"
  end

  test "boot logs are read in pages that end on a line, scrubbed of the session's secrets" do
    sandbox = sandbox_double(rails_origin!)
    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE).to_h) }
    # The server's log is written as the app prints it.
    workspace(sandbox).join("logs/server.log").open("a") do |file|
      file.puts("token #{GITHUB_TOKEN}")
      file.puts("credential #{CLAUDE_CREDENTIAL}")
      file.puts("extra #{SECRET}")
    end

    full = @backend.boot_log(sandbox, step: "start", limit: 1_000_000, secrets: [ SECRET ])
    assert full[:eof]
    assert_equal full[:size], full[:next_offset]
    assert_includes full[:text], "token [REDACTED]"
    assert_includes full[:text], "credential [REDACTED]"
    assert_includes full[:text], "extra [REDACTED]"

    pages = []
    offset = 0
    loop do
      page = @backend.boot_log(sandbox, step: "start", offset: offset, limit: 100, secrets: [ SECRET ])
      pages << page[:text]
      offset = page[:next_offset]
      break if page[:eof]
    end
    assert_equal full[:text], pages.join
    assert pages[0...-1].all? { |text| text.end_with?("\n") }

    assert_nil @backend.boot_log(sandbox, step: "no_such_step")
    assert_equal "bundle_config", @backend.boot_log(sandbox, step: "bundle_config")[:step]
  end

  test "a spec for checkouts without the engine leaves one with its own manifest to its sandbox.yml" do
    yml = { "setup" => [ "true" ], "manifest" => ruby_command("fake_manifest"), "start" => ruby_command("fake_app_server") }.to_yaml
    sandbox = sandbox_double(rails_origin!(files: { ".activeagents/sandbox.yml" => yml }))
    spec = Spec.bootstrap(engine: ENGINE, apply: "without_engine")

    result = with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec.to_h) }

    assert result[:mcp_url].present?
    assert_empty tool_calls
    assert_equal "config", @backend.boot_status(sandbox)[:mode]
  end

  test "a spec for checkouts without the engine leaves alone one that bundles it" do
    sandbox = sandbox_double(rails_origin!(gems: [ "actionagent (1.8.1)", "activeagent (1.8.1)" ]))
    spec = Spec.bootstrap(engine: ENGINE, apply: "without_engine")

    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec.to_h) }

    assert_equal [ "config", [] ], @backend.boot_status(sandbox).values_at(:mode, :resumable_steps)
    assert_equal [ "bundle install", "rails db:prepare", "rails action_agent:sandbox:manifest" ], tool_calls.first(3)
  end

  test "a checkout that bundles the engine boots as its sandbox.yml says, with the spec's secrets" do
    control("echo" => "STRIPE_KEY")
    sandbox = sandbox_double(rails_origin!(gems: [ "actionagent (1.8.1)", "activeagent (1.8.1)" ]))
    spec = Spec.bootstrap(engine: ENGINE, apply: "without_engine", secrets: { "STRIPE_KEY" => SECRET })

    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec.to_h) }

    assert_equal "config", @backend.boot_status(sandbox)[:mode]
    setup_log = workspace(sandbox).join("logs/setup.log").read
    assert_includes setup_log, "fake rails: db:prepare sees [REDACTED]", "the step had the value, and its output is masked"
    assert_not_includes setup_log, SECRET
  end

  test "a checkout that bundles the engine also gets the spec's env, unmasked" do
    control("echo" => "REDIS_URL")
    sandbox = sandbox_double(rails_origin!(gems: [ "actionagent (1.8.1)", "activeagent (1.8.1)" ]))
    spec = Spec.bootstrap(engine: ENGINE, apply: "without_engine", env: { "REDIS_URL" => "redis://127.0.0.1:6379/4" })

    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: spec.to_h) }

    assert_includes workspace(sandbox).join("logs/setup.log").read, "fake rails: db:prepare sees redis://127.0.0.1:6379/4"
  end

  test "boot logs are scrubbed of the secrets of the project the sandbox was booted for" do
    sandbox = sandbox_double(rails_origin!)
    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE).to_h) }
    encoded = [ SECRET ].pack("m0")
    sandbox.define_singleton_method(:project_scrub_values) { ActionAgent::SecretScrubber.with_encodings([ SECRET ]) }
    workspace(sandbox).join("logs/server.log").open("a") { |file| file.puts("project #{SECRET} #{encoded}") }

    text = @backend.boot_log(sandbox, step: "start", limit: 1_000_000)[:text]

    assert_includes text, "project [REDACTED] [REDACTED]"
  end

  test "a spec for checkouts without the engine bootstraps one that lacks it" do
    sandbox = sandbox_double(rails_origin!)

    with_fake_tools { @backend.create_sandbox(sandbox, boot_config: Spec.bootstrap(engine: ENGINE, apply: "without_engine").to_h) }

    assert_equal "spec", @backend.boot_status(sandbox)[:mode]
    assert_includes tool_calls, "bundle add actionagent --version ~> 1.9.0"
  end

  test "a malformed spec is refused before anything is cloned" do
    sandbox = sandbox_double(rails_origin!)

    error = assert_raises(Backend::Error) { @backend.create_sandbox(sandbox, boot_config: { "kind" => "bootstrap", "timeout" => 5 }) }

    assert_match(/\ASandbox boot spec is invalid: a bootstrap boot needs a timeout of at least 1800s/, error.message)
    assert_not ActionAgent.local_sandbox_root.join(sandbox.session_id).exist?
  end

  private

  def sandbox_double(clone_url)
    SandboxDouble.new(
      session_id: SecureRandom.uuid,
      sandbox_type: "app_runtime",
      checkout_spec: {
        repository: "acme/shop", ref: "main", clone_url: clone_url, username: "x-access-token", token: GITHUB_TOKEN
      },
      runtime_environment: { "ANTHROPIC_API_KEY" => CLAUDE_CREDENTIAL }
    )
  end

  def workspace(sandbox)
    ActionAgent.local_sandbox_root.join(sandbox.session_id)
  end

  def rails_lock(ruby: "3.3.6p0", railties: "8.0.1", gems: [])
    specs = [ "rails (#{railties})", "railties (#{railties})", *gems ].sort.map { |spec| "    #{spec}\n" }.join
    lock = +"GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  rails\n"
    lock << "\nRUBY VERSION\n   ruby #{ruby}\n" if ruby
    lock << "\nBUNDLED WITH\n   2.6.2\n"
  end

  # A Rails app's skeleton, committed to a new repository. +lock+ nil
  # commits no Gemfile.lock; +application+ false no config/application.rb.
  def rails_origin!(lock: :default, ruby: "3.3.6p0", railties: "8.0.1", gems: [], application: true, files: {})
    lock = rails_lock(ruby: ruby, railties: railties, gems: gems) if lock == :default
    tree = {
      ".gitignore" => "/.bundle\n/tmp/\n",
      "Gemfile" => "source \"https://rubygems.org\"\n\ngem \"rails\"\n",
      "config/routes.rb" => "Rails.application.routes.draw do\nend\n",
      "bin/rails" => "#!/bin/sh\nexec #{[ RbConfig.ruby, File.join(FIXTURES, "fake_rails.rb") ].shelljoin} \"$@\"\n"
    }
    tree["Gemfile.lock"] = lock if lock
    tree["config/application.rb"] = "# A Rails application\n" if application

    origin = @tmp.join("origin-#{SecureRandom.hex(4)}")
    tree.merge(files).each do |path, content|
      origin.join(path).dirname.mkpath
      origin.join(path).write(content)
      origin.join(path).chmod(0o755) if path.start_with?("bin/")
    end
    git(origin, "init", "-q", "-b", "main")
    git(origin, "add", "-A")
    git(origin, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false",
      "commit", "-q", "-m", "Fixture app")
    "file://#{origin}"
  end

  # Runs the block with the fake bundle first on the PATH the sandbox's
  # processes get, and the fakes' log and control file in their environment.
  def with_fake_tools(&block)
    environment = Bundler.unbundled_env.merge(
      "PATH" => [ @bin.to_s, Bundler.unbundled_env["PATH"] ].join(File::PATH_SEPARATOR),
      "FAKE_TOOLS_LOG" => @tools_log.to_s, "FAKE_CONTROL" => @control.to_s
    )
    Bundler.stub(:unbundled_env, environment, &block)
  end

  def control(settings)
    @control.write(JSON.generate(settings))
  end

  def tool_calls
    @tools_log.read.lines.map(&:chomp)
  end

  def git(dir, *args)
    system("git", "-C", dir.to_s, *args, out: File::NULL, err: File::NULL, exception: true)
  end

  def git_output(dir, *args)
    output, status = Open3.capture2("git", "-C", dir.to_s, *args)
    assert status.success?
    output
  end

  def ruby_command(script, *args)
    [ RbConfig.ruby, File.join(FIXTURES, "#{script}.rb"), *args ].shelljoin
  end

  def rpc(uri, token:)
    request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream")
    request["Authorization"] = "Bearer #{token}"
    request.body = JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list")
    Net::HTTP.new(uri.host, uri.port, nil).start { |connection| connection.request(request) }
  end
end
