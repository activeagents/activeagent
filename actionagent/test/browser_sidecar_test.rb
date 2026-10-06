# frozen_string_literal: true

require "test_helper"
require "rake"

# Finding, checking and installing the browser sidecar for the :local
# backend. Node and npm are shell scripts that answer as the real ones would
# and write down how they were run.
class BrowserSidecarTest < ActiveSupport::TestCase
  Sidecar = ActionAgent::BrowserSidecar

  CONFIG = %i[browser_sidecar_path node_command npm_command local_sandbox_root].freeze

  def setup
    super
    @tmp = Pathname(Dir.mktmpdir("browser-sidecar-test")).realpath
    @saved = CONFIG.index_with { |name| ActionAgent.instance_variable_get(:"@#{name}") }
    ActionAgent.local_sandbox_root = @tmp.join("sandboxes").to_s
    ActionAgent.browser_sidecar_path = nil
  end

  def teardown
    @saved.each { |name, value| ActionAgent.instance_variable_set(:"@#{name}", value) }
    FileUtils.rm_rf(@tmp)
    super
  end

  test "every check passes with Node, the engine's sidecar and Chromium installed" do
    fake_node
    install_package

    checks = Sidecar.checks

    assert_equal %w[node sidecar chromium], checks.map(&:name)
    assert checks.all?(&:ok), checks.map(&:message).inspect
    assert_equal "Browser sidecar #{ActionAgent::VERSION}", checks[1].detail
    assert_nil Sidecar.refusal
  end

  test "Node that is missing or too old is named, with the setting to change" do
    ActionAgent.node_command = @tmp.join("no-such-node").to_s
    assert_match(/Node\.js was not found .*Install Node\.js 20 or later, or set ActionAgent\.node_command/, Sidecar.refusal)
    assert_equal [ "node" ], Sidecar.checks.map(&:name)

    fake_node(node_version: "v18.19.0")
    assert_match(/Node\.js 18\.19\.0 is older than 20/, Sidecar.refusal)
  end

  test "a sidecar that is missing, of another version, or without Chromium names the install command" do
    fake_node
    assert_match(/browser sidecar is not installed .*Run bin\/rails action_agent:browser:install\z/, Sidecar.refusal)

    install_package
    fake_node(sidecar_version: "0.0.1")
    assert_match(/version 0\.0\.1, and this dashboard needs #{Regexp.escape(ActionAgent::VERSION)}\. Run bin\/rails action_agent:browser:install/,
      Sidecar.refusal)

    fake_node(chromium: false)
    assert_match(/Chromium is not installed \(#{Regexp.escape(Sidecar.browsers_path.to_s)}\)\. Run bin\/rails action_agent:browser:install/,
      Sidecar.refusal)
  end

  test "a checkout of the sidecar is run whatever its version" do
    fake_node(sidecar_version: "0.0.1")
    checkout = @tmp.join("browser-sidecar")
    checkout.join("bin").mkpath
    checkout.join(Sidecar::ENTRYPOINT).write("")
    ActionAgent.browser_sidecar_path = checkout.to_s

    assert_nil Sidecar.refusal
    assert_equal [ ActionAgent.node_command, checkout.join(Sidecar::ENTRYPOINT).to_s, "serve" ], Sidecar.command("serve")
  end

  test "install puts the engine's version of the package and its Chromium under the sandbox root" do
    log = fake_node
    fake_npm(log)
    output = StringIO.new

    Sidecar.install!(output)

    calls = log.read.lines.map(&:strip)
    assert_equal "npm install --no-audit --no-fund --save-exact @activeagents/browser-sidecar@#{ActionAgent::VERSION} in #{Sidecar.root}", calls.first
    assert_equal "node #{Sidecar.package_dir.join(Sidecar::ENTRYPOINT)} install-browser browsers=#{Sidecar.browsers_path}", calls.last
    assert JSON.parse(Sidecar.root.join("package.json").read)["private"]
    assert_includes output.string, "$ #{ActionAgent.npm_command} install"
  end

  test "install runs npm ci in a checkout" do
    log = fake_node
    fake_npm(log)
    checkout = @tmp.join("browser-sidecar").tap(&:mkpath)
    ActionAgent.browser_sidecar_path = checkout.to_s

    Sidecar.install!(StringIO.new)

    assert_equal "npm ci in #{checkout}", log.read.lines.first.strip
  end

  test "a failing install step stops the install" do
    log = fake_node
    fake_npm(log, fail: true)

    error = assert_raises(Sidecar::Error) { Sidecar.install!(StringIO.new) }

    assert_match(/npm install .* failed/, error.message)
    assert_equal 1, log.read.lines.size, "Chromium is not installed after a failed package install"
  end

  test "the doctor task prints each check, and fails while one does" do
    fake_node
    install_package

    output = capture_io { run_task("action_agent:browser:doctor") }.first
    assert_match(/\[ok\] +node: Node\.js 20\.11\.1/, output)
    assert_match(/\[ok\] +chromium: Chromium at \/fake\/chromium/, output)
    assert_match(/Browser sessions can start on this machine/, output)

    fake_node(chromium: false)
    assert_raises(SystemExit) { capture_io { run_task("action_agent:browser:doctor") } }
  end

  private

  # A `node` that answers --version, and `check` for the sidecar, and writes
  # every other run to the returned log.
  def fake_node(node_version: "v20.11.1", sidecar_version: ActionAgent::VERSION, chromium: true)
    log = @tmp.join("calls.log").tap { |file| file.write("") unless file.exist? }
    report = JSON.generate("version" => sidecar_version, "node" => node_version,
      "chromium" => { "installed" => chromium, "executable" => "/fake/chromium" })
    node = @tmp.join("node-#{SecureRandom.hex(3)}")
    node.write(<<~SH)
      #!/bin/sh
      if [ "$1" = "--version" ]; then echo #{node_version}; exit 0; fi
      if [ "$2" = "check" ]; then echo '#{report}'; exit 0; fi
      echo "node $* browsers=$PLAYWRIGHT_BROWSERS_PATH" >> #{log.to_s.shellescape}
    SH
    node.chmod(0o755)
    ActionAgent.node_command = node.to_s
    log
  end

  def fake_npm(log, fail: false)
    npm = @tmp.join("npm")
    npm.write("#!/bin/sh\necho \"npm $* in $(pwd -P)\" >> #{log.to_s.shellescape}\n#{'exit 1' if fail}\n")
    npm.chmod(0o755)
    ActionAgent.npm_command = npm.to_s
  end

  def install_package
    entrypoint = Sidecar.package_dir.join(Sidecar::ENTRYPOINT)
    entrypoint.dirname.mkpath
    entrypoint.write("")
  end

  def run_task(name)
    original = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    ActionAgent::Engine.instance.load_tasks
    Rake::Task[name].invoke
  ensure
    Rake.application = original
  end
end
