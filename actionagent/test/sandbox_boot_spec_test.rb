# frozen_string_literal: true

require "test_helper"

# Boot specs: the bootstrap spec the engine builds for a checkout without the
# engine, what a spec may hold, and how the orchestrator hands one to a
# backend as data.
class SandboxBootSpecTest < ActiveSupport::TestCase
  Spec = ActionAgent::SandboxBootSpec
  SECRET = "fixture-boot-spec-secret-0123456789"

  RUBYGEMS = {
    "activeagent" => { "source" => "rubygems", "version" => "1.9.0" },
    "actionagent" => { "source" => "rubygems", "version" => "1.9.0" }
  }.freeze

  LockedGems = Struct.new(:specs)
  LockedSpec = Struct.new(:name, :source)

  # Takes a boot spec, and records how each verb was called.
  class SpecBackend
    class << self
      attr_accessor :calls
    end
    self.calls = []

    def create_sandbox(session, boot_config: nil)
      self.class.calls << [ :create, session, boot_config ]
      { container_name: "spec-#{session}" }
    end

    def resume_boot(session, from:, boot_config: nil)
      self.class.calls << [ :resume_boot, session, from, boot_config ]
      { container_name: "spec-#{session}" }
    end

    def status(_handle) = {}
    def terminate(_handle) = true
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  # Predates boot specs.
  class PlainBackend
    class << self
      attr_accessor :calls
    end
    self.calls = []

    def create_sandbox(session)
      self.class.calls << [ :create, session ]
      { container_name: "plain-#{session}" }
    end

    def status(_handle) = {}
    def terminate(_handle) = true
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  def setup
    @original_backends = ActionAgent.sandbox_backends
    ActionAgent.sandbox_backends = { "spec" => SpecBackend.name, "plain" => PlainBackend.name }
    SpecBackend.calls = []
    PlainBackend.calls = []
  end

  def teardown
    ActionAgent.sandbox_backends = @original_backends
  end

  test "the bootstrap spec installs the engine at this dashboard's version, then boots the app" do
    spec = Spec.bootstrap(engine: RUBYGEMS)

    assert spec.bootstrap?
    assert spec.preflight?
    assert_not spec.keep_on_failure?
    assert_equal "/", spec.start_url
    assert_equal 1800, spec.timeout
    assert_equal %w[
      bundle_config bundle_install add_engine install_framework install_engine
      javascript_build css_build tailwindcss_build db_prepare
    ], spec.steps.map { |step| step["name"] }

    commands = spec.steps.to_h { |step| [ step["name"], step["command"] ] }
    assert_equal "bundle config set --local frozen false", commands["bundle_config"]
    assert_equal 'bundle add actionagent --version "~> 1.9.0"', commands["add_engine"]
    assert_equal "bin/rails generate active_agent:install --skip", commands["install_framework"]
    assert_equal "bin/rails generate action_agent:install --skip", commands["install_engine"]
    assert_equal "bin/rails db:prepare", commands["db_prepare"]
    assert_equal "bin/rails action_agent:sandbox:manifest", spec.manifest["command"]
    assert_equal "bin/rails server -b 127.0.0.1 -p $PORT", spec.start["command"]

    conditions = spec.steps.to_h { |step| [ step["name"], step.slice("unless_locked", "if_task") ] }
    assert_equal({ "unless_locked" => "actionagent" }, conditions["add_engine"])
    assert_equal({ "unless_locked" => "activeagent" }, conditions["install_framework"])
    assert_equal({ "unless_locked" => "actionagent" }, conditions["install_engine"])
    assert_equal({ "if_task" => "javascript:build" }, conditions["javascript_build"])
    assert_equal({ "if_task" => "css:build" }, conditions["css_build"])
    assert_equal({ "if_task" => "tailwindcss:build" }, conditions["tailwindcss_build"])
    assert_equal({}, conditions["db_prepare"])
    assert spec.steps.all? { |step| step["timeout"].positive? }
  end

  test "a bootstrap takes the engine from the same git revision or path as this dashboard" do
    git = Spec.bootstrap(engine: {
      "activeagent" => { "source" => "git", "uri" => "https://github.com/acme/agents.git", "ref" => "a" * 40 },
      "actionagent" => { "source" => "git", "uri" => "https://github.com/acme/agents.git", "ref" => "a" * 40 }
    })
    path = Spec.bootstrap(engine: {
      "activeagent" => { "source" => "path", "path" => "/src/my agents" },
      "actionagent" => { "source" => "path", "path" => "/src/my agents/actionagent" }
    })

    git_steps = git.steps.to_h { |step| [ step["name"], step ] }
    assert_equal "bundle add activeagent --git https://github.com/acme/agents.git --ref #{"a" * 40} --skip-install",
      git_steps["add_framework"]["command"]
    assert_equal "activeagent", git_steps["add_framework"]["unless_locked"]
    assert_equal "bundle add actionagent --git https://github.com/acme/agents.git --ref #{"a" * 40}", git_steps["add_engine"]["command"]

    path_steps = path.steps.to_h { |step| [ step["name"], step["command"] ] }
    assert_equal 'bundle add activeagent --path /src/my\ agents --skip-install', path_steps["add_framework"]
    assert_equal 'bundle add actionagent --path /src/my\ agents/actionagent', path_steps["add_engine"]
    assert_equal %w[bundle_config bundle_install add_framework add_engine], path.steps.first(4).map { |step| step["name"] }
  end

  test "the engine's gems are read from the dashboard's own lock" do
    git = Bundler::Source::Git.new("uri" => "https://github.com/acme/agents.git", "revision" => "b" * 40)
    path = Bundler::Source::Path.new("path" => "/src/agents/actionagent")
    locked = LockedGems.new([ LockedSpec.new("activeagent", git), LockedSpec.new("actionagent", path) ])

    assert_equal({
      "activeagent" => { "source" => "git", "uri" => "https://github.com/acme/agents.git", "ref" => "b" * 40 },
      "actionagent" => { "source" => "path", "path" => "/src/agents/actionagent" }
    }, Spec.engine_gems(locked))

    assert_equal({
      "activeagent" => { "source" => "rubygems", "version" => ActiveAgent::VERSION },
      "actionagent" => { "source" => "rubygems", "version" => ActionAgent::VERSION }
    }, Spec.engine_gems(nil))

    # This repository's own bundle takes both from the working tree.
    assert_equal %w[path path], Spec.engine_gems.values.map { |source| source["source"] }
  end

  test "a git source with credentials in its URL is refused rather than written into a checkout" do
    git = Bundler::Source::Git.new("uri" => "https://x-access-token:#{SECRET}@github.com/acme/agents.git", "revision" => "c" * 40)
    locked = LockedGems.new([ LockedSpec.new("actionagent", git) ])

    error = assert_raises(Spec::Invalid) { Spec.engine_gems(locked) }
    assert_match(/bundles actionagent from a git URL with credentials/, error.message)
    assert_not_includes error.message, SECRET
  end

  test "a spec is plain JSON, and reads back the same" do
    spec = Spec.bootstrap(engine: RUBYGEMS, start_url: "/dashboard?tab=1", keep_on_failure: true,
      env: { "RAILS_ENV" => "development", "WORKERS" => 2 }, secrets: { "STRIPE_KEY" => SECRET })

    data = JSON.parse(JSON.generate(spec.to_h))

    assert_equal spec.to_h, Spec.wrap(data).to_h
    assert_equal({ "RAILS_ENV" => "development", "WORKERS" => "2" }, spec.env)
    assert_equal({ "RAILS_ENV" => "development", "WORKERS" => "2", "STRIPE_KEY" => SECRET }, spec.step_environment)
    assert_equal [ SECRET ], spec.secret_values
    assert_equal spec, Spec.wrap(spec)
    assert_nil Spec.wrap(nil)
    assert_equal spec.to_h, Spec.wrap(spec.to_h.deep_symbolize_keys).to_h
  end

  test "a redacted spec names its secrets without their values, and reads back as missing them" do
    spec = Spec.bootstrap(engine: RUBYGEMS, secrets: { "STRIPE_KEY" => SECRET, "MAILER_PASSWORD" => "another-secret-0123" })

    redacted = spec.redacted

    assert_not_includes JSON.generate(redacted), SECRET
    assert_not_includes JSON.generate(redacted), "another-secret-0123"
    assert_equal %w[STRIPE_KEY MAILER_PASSWORD], redacted["secret_names"]
    assert_empty spec.missing_secrets
    assert_equal %w[STRIPE_KEY MAILER_PASSWORD], Spec.wrap(redacted).missing_secrets
    assert_empty Spec.wrap(redacted).secret_values
  end

  test "a spec refuses what no backend could run" do
    base = { "kind" => "custom", "steps" => [ { "name" => "setup_app", "command" => "bin/setup" } ] }
    {
      { "kind" => "other" } => /`kind` must be one of/,
      { "apply" => "sometimes" } => /`apply` must be one of/,
      { "steps" => "bin/setup" } => /`steps` must be a list/,
      { "steps" => [ { "name" => "Setup", "command" => "x" } ] } => /is not a step name/,
      { "steps" => [ { "name" => "manifest", "command" => "x" } ] } => /is not a step name/,
      { "steps" => [ { "name" => "a", "command" => "x" }, { "name" => "a", "command" => "y" } ] } => /must be unique \(a is not\)/,
      { "steps" => [ { "name" => "a", "command" => " " } ] } => /step a needs a command/,
      { "steps" => [ { "name" => "a", "command" => "x", "timeout" => 0 } ] } => /step a's timeout must be/,
      { "steps" => [ { "name" => "a", "command" => "x", "unless_locked" => "../x" } ] } => /must name a gem/,
      { "steps" => [ { "name" => "a", "command" => "x", "if_task" => "a b" } ] } => /must name a Rake task/,
      { "env" => { "1BAD" => "x" } } => /`env` must map variable names to strings/,
      { "env" => { "LIST" => [ 1 ] } } => /`env` must map variable names to strings/,
      { "start_url" => "https://elsewhere.test/" } => /`start_url` must be a path/,
      { "start_url" => "//elsewhere.test/" } => /`start_url` must be a path/,
      { "start_url" => "/a b" } => /`start_url` must be a path/,
      { "timeout" => 7 * 3600 } => /timeout must be a number of seconds/,
      { "kind" => "bootstrap", "timeout" => 600 } => /bootstrap boot needs a timeout of at least 1800s/
    }.each do |change, message|
      error = assert_raises(Spec::Invalid, change.inspect) { Spec.new(base.merge(change)) }
      assert_match message, error.message, change.inspect
    end
    assert_raises(Spec::Invalid) { Spec.wrap("bootstrap") }
  end

  test "secrets cannot set what the backend sets, nor what changes how code is loaded" do
    %w[
      PORT DATABASE_URL QUEUE_DATABASE_URL ACTION_AGENT_SANDBOX_MANIFEST RUBYOPT RUBYLIB LD_PRELOAD DYLD_INSERT_LIBRARIES
      BUNDLE_GEMFILE GIT_DIR PATH NODE_OPTIONS
    ].each do |name|
      error = assert_raises(Spec::Invalid, name) { Spec.new("secrets" => { name => "value-0123456789" }) }
      assert_match(/secrets may not set #{name}/, error.message)
    end

    assert_equal({ "STRIPE_API_KEY" => "v" }, Spec.new("secrets" => { "STRIPE_API_KEY" => "v" }).secrets)
    # The engine's own settings go in env, which may name them.
    assert_equal({ "DATABASE_URL" => "sqlite3:db/x.sqlite3" }, Spec.new("env" => { "DATABASE_URL" => "sqlite3:db/x.sqlite3" }).env)
  end

  test "the orchestrator hands a backend that takes a spec the whole spec, as data" do
    spec = Spec.bootstrap(engine: RUBYGEMS, secrets: { "STRIPE_KEY" => SECRET })
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "spec")

    result = orchestrator.create_sandbox("s1", boot_config: spec)
    orchestrator.create_sandbox("s2")
    orchestrator.resume_boot("s1", from: "db_prepare", boot_config: spec.to_h)
    orchestrator.resume_boot("s1", from: nil)

    assert_equal "spec-s1", result[:sandbox_id]
    assert_equal [
      [ :create, "s1", spec.to_h ],
      [ :create, "s2", nil ],
      [ :resume_boot, "s1", "db_prepare", spec.to_h ],
      [ :resume_boot, "s1", nil, nil ]
    ], SpecBackend.calls
    assert_equal SECRET, SpecBackend.calls.first.last.dig("secrets", "STRIPE_KEY"), "in memory, the secrets go along"
    assert_raises(Spec::Invalid) { orchestrator.create_sandbox("s3", boot_config: { "kind" => "nope" }) }
  end

  test "a backend that predates specs boots as it always has, unless the spec must apply" do
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "plain")

    orchestrator.create_sandbox("s1", boot_config: Spec.bootstrap(engine: RUBYGEMS, apply: "without_engine"))
    error = assert_raises(ActionAgent::SandboxOrchestrator::UnsupportedBackendError) do
      orchestrator.create_sandbox("s2", boot_config: Spec.bootstrap(engine: RUBYGEMS))
    end

    assert_equal [ [ :create, "s1" ] ], PlainBackend.calls
    assert_match(/plain sandbox backend cannot boot a checkout from a boot spec/, error.message)
  end

  test "a sandbox request's boot options are checked, and name the spec they ask for" do
    assert_equal({ "bootstrap" => "auto", "start_url" => "/", "keep_on_failure" => false }, Spec.request_options)
    assert_equal({ "bootstrap" => "always", "start_url" => "/up", "keep_on_failure" => true },
      Spec.request_options(bootstrap: true, start_url: "/up", keep_on_failure: "true"))
    assert_equal "never", Spec.request_options(bootstrap: "false")["bootstrap"]
    assert_raises(Spec::Invalid) { Spec.request_options(bootstrap: "sometimes") }
    assert_raises(Spec::Invalid) { Spec.request_options(start_url: "https://elsewhere.test/") }

    Spec.stub(:engine_gems, RUBYGEMS) do
      assert_nil Spec.for_request("bootstrap" => "never")
      auto = Spec.for_request({})
      assert_equal [ "bootstrap", "without_engine", "/", false ], [ auto.kind, auto.apply, auto.start_url, auto.keep_on_failure? ]
      always = Spec.for_request("bootstrap" => "always", "start_url" => "/up", "keep_on_failure" => true)
      assert_equal [ "always", "/up", true ], [ always.apply, always.start_url, always.keep_on_failure? ]
    end
  end

  test "the mock backend records the spec it was given without the secrets' values" do
    session = Struct.new(:session_id, :checkout_spec, :runtime_environment).new(
      "s1", { repository: "acme/shop", token: "ghs_mockToken0123456789" }, {}
    )
    spec = Spec.bootstrap(engine: RUBYGEMS, secrets: { "STRIPE_KEY" => SECRET })

    created = ActionAgent::MockSandboxBackend.new.create_sandbox(session, boot_config: spec.to_h)

    assert_equal spec.redacted, created[:boot_config]
    assert_not_includes created.to_json, SECRET
    assert_nil ActionAgent::MockSandboxBackend.new.create_sandbox(session)[:boot_config]
  end

  test "an always step runs whether the spec applies or not, so it cannot hang on the checkout's lock" do
    step = { "name" => "write_tools", "command" => "bin/rails runner 1", "always" => true }
    spec = Spec.new("apply" => "without_engine", "steps" => [ step, { "name" => "install", "command" => "bundle install" } ])

    assert_equal [ "write_tools" ], spec.always_steps.map { |entry| entry["name"] }
    assert_equal spec.to_h, Spec.wrap(JSON.parse(JSON.generate(spec.to_h))).to_h, "the flag reads back"
    assert_raises(Spec::Invalid) { Spec.new("steps" => [ step.merge("always" => "yes") ]) }
    error = assert_raises(Spec::Invalid) { Spec.new("steps" => [ step.merge("unless_locked" => "actionagent") ]) }
    assert_match(/runs always/, error.message)
  end

  test "a bootstrap holds as many schema tools steps as choices can make" do
    columns = (1..100).map { |index| "c#{index.to_s.rjust(3, "0")}_#{"x" * 10}" }
    choices = (1..Spec::MAX_SCHEMA_TOOL_MODELS).map { |index| { "model" => "Model#{index}", "filterable" => columns, "returns" => columns } }

    error = assert_raises(Spec::Invalid) { Spec.schema_tools_steps(choices) }
    assert_match(/more than #{Spec::MAX_SCHEMA_TOOL_STEPS} boot steps/, error.message)

    fitting = choices.first(Spec::MAX_SCHEMA_TOOL_STEPS)
    steps = Spec.schema_tools_steps(fitting)
    assert_equal Spec::MAX_SCHEMA_TOOL_STEPS, steps.size
    git = { "source" => "git", "uri" => "https://github.com/acme/agents.git", "ref" => "a" * 40 }
    bootstrap = Spec.bootstrap(engine: { "activeagent" => git, "actionagent" => git }, steps: steps)
    assert_operator bootstrap.steps.size, :<=, Spec::MAX_STEPS, "the bootstrap with the most steps of its own still fits them"
  end
end
