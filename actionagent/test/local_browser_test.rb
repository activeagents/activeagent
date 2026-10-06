# frozen_string_literal: true

require "test_helper"

# The :local backend's browser: the sidecar runs as a process group of its
# own, gets its configuration on stdin, is recorded in state.json beside the
# app, and goes when the browser or the sandbox is stopped. Node is
# test/support/local_sandbox/fake_browser_sidecar.rb behind a wrapper, so
# these run real processes without Node or Chromium.
class LocalBrowserTest < ActiveSupport::TestCase
  Backend = ActionAgent::LocalSandboxBackend

  FIXTURES = File.expand_path("support/local_sandbox", __dir__)
  TOKEN = "aabrw_localBrowserToken0123456789abcdefghij"
  RECORDING_TOKEN = "aarec_localRecordingToken0123456789abcdef"

  SandboxDouble = Struct.new(:session_id, :browser_launch, keyword_init: true)

  CONFIG = %i[browser_sidecar_path node_command browser_start_timeout local_sandbox_root].freeze

  def setup
    super
    @tmp = Pathname(Dir.mktmpdir("local-browser-test")).realpath
    @saved = CONFIG.index_with { |name| ActionAgent.instance_variable_get(:"@#{name}") }
      .merge(local_sandboxes_enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled))
    ActionAgent.local_sandboxes_enabled = true
    ActionAgent.local_sandbox_root = @tmp.join("sandboxes").to_s
    ActionAgent.browser_start_timeout = 20
    install_fake_sidecar
    @backend = Backend.new

    # The tests talk to the fake over loopback, which VCR and WebMock refuse
    # by default.
    config = WebMock::Config.instance
    @webmock = [ config.allow_net_connect, config.allow_localhost, config.allow, config.net_http_connect_on_start ]
    VCR.turn_off!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  def teardown
    root = ActionAgent.local_sandbox_root
    root.children.each { |dir| @backend.terminate("local-#{dir.basename}") if dir.directory? && !dir.basename.to_s.start_with?(".") } if root.directory?
    @saved.each { |name, value| ActionAgent.instance_variable_set(:"@#{name}", value) }
    VCR.turn_on!
    config = WebMock::Config.instance
    config.allow_net_connect, config.allow_localhost, config.allow, config.net_http_connect_on_start = @webmock
    FileUtils.rm_rf(@tmp)
    super
  end

  test "a browser starts with its token on stdin, answers only with it, and terminate stops it with the sandbox" do
    sandbox = booted_sandbox

    result = @backend.start_browser(sandbox, mode: :headless)

    assert_match %r{\Ahttp://127\.0\.0\.1:\d+/mcp\z}, result[:mcp_url]
    assert_equal TOKEN, result[:mcp_token]
    assert_not result.key?(:live_url), "no live view was asked for"
    record = sidecar_record(sandbox)
    assert_equal TOKEN, record.dig("config", "token")
    assert_equal "http://127.0.0.1:4100", record.dig("config", "app_url")
    assert_equal "headless", record.dig("config", "mode")
    assert_equal [ "testing" ], record.dig("config", "capabilities")
    assert_equal({ "url" => "http://127.0.0.1:3000/activeagents/api/session_recordings/7/events", "token" => RECORDING_TOKEN,
                   "batch_events" => 1000, "batch_bytes" => 1_048_576 }, record.dig("config", "recording"))
    assert_equal sandbox.browser_launch[:stop_at].to_i * 1000, record.dig("config", "stop_at")
    assert_equal record["pid"], record["pgid"], "the sidecar leads its own process group"
    assert_equal record.dig("config", "workdir"), record["cwd"]
    [ TOKEN, RECORDING_TOKEN ].each do |secret|
      assert_not_includes record["argv"].join(" "), secret, "a token in argv shows in every process listing"
      assert_not_includes record["env"].values.join(" "), secret
    end
    assert_equal sandbox.session_id, record.dig("env", Backend::SESSION_ID_ENV)
    assert_equal ActionAgent::BrowserSidecar.browsers_path.to_s, record.dig("env", "PLAYWRIGHT_BROWSERS_PATH")
    assert_equal record["pid"], state(sandbox).dig("browser", "pid")

    uri = URI(result[:mcp_url])
    assert_equal "401", rpc(uri, token: nil).code
    assert_equal "200", rpc(uri, token: TOKEN).code

    assert @backend.terminate("local-#{sandbox.session_id}")

    assert_gone record["pid"], record["child_pid"]
    assert_not workspace(sandbox).exist?
  end

  test "a browser started with a live view is told its session and origins, and reports where viewers connect" do
    sandbox = booted_sandbox
    sandbox.browser_launch[:live] = { session_id: sandbox.session_id, origins: [ "http://localhost:3000" ] }

    result = @backend.start_browser(sandbox, mode: :headless)

    assert_equal({ "session_id" => sandbox.session_id, "origins" => [ "http://localhost:3000" ] }, sidecar_record(sandbox).dig("config", "live"))
    assert_equal "ws://127.0.0.1:#{URI(result[:mcp_url]).port}/live", result[:live_url]
  end

  test "stopping the browser stops its process group and removes its directory, and leaves the sandbox" do
    sandbox = booted_sandbox
    @backend.start_browser(sandbox, mode: :headless)
    record = sidecar_record(sandbox)
    dir = Pathname(record.dig("config", "workdir"))

    assert @backend.stop_browser(sandbox)

    assert_gone record["pid"], record["child_pid"]
    assert_not dir.exist?
    assert_nil state(sandbox)["browser"]
    assert workspace(sandbox).join("app").directory?
    assert @backend.stop_browser(sandbox), "stopping is idempotent"
  end

  test "starting again replaces the sandbox's browser" do
    sandbox = booted_sandbox
    @backend.start_browser(sandbox, mode: :headless)
    first = sidecar_record(sandbox)

    @backend.start_browser(sandbox, mode: :headless)

    assert_gone first["pid"], first["child_pid"]
    assert_not_equal first["pid"], state(sandbox).dig("browser", "pid")
  end

  test "a missing sidecar or Chromium is refused with the command that installs it, and nothing is started" do
    sandbox = booted_sandbox

    install_fake_sidecar(chromium: false)
    error = assert_raises(Backend::Error) { @backend.start_browser(sandbox, mode: :headless) }
    assert_match(/Chromium is not installed .*Run bin\/rails action_agent:browser:install/, error.message)

    ActionAgent.browser_sidecar_path = nil
    error = assert_raises(Backend::Error) { @backend.start_browser(sandbox, mode: :headless) }
    assert_match(/browser sidecar is not installed .*Run bin\/rails action_agent:browser:install/, error.message)

    assert_nil state(sandbox)["browser"]
  end

  test "an installed sidecar of another version is refused" do
    sandbox = booted_sandbox
    install_fake_sidecar(version: "0.0.1", checkout: false)

    error = assert_raises(Backend::Error) { @backend.start_browser(sandbox, mode: :headless) }

    assert_match(/version 0\.0\.1, and this dashboard needs #{Regexp.escape(ActionAgent::VERSION)}/, error.message)
    assert_nil state(sandbox)["browser"]
  end

  test "a checkout of the sidecar runs whatever its version" do
    sandbox = booted_sandbox
    install_fake_sidecar(version: "0.0.1")

    assert @backend.start_browser(sandbox, mode: :headless)[:mcp_url]
  end

  test "a sidecar that exits before it is ready fails the start with its log, without the tokens" do
    sandbox = booted_sandbox
    install_fake_sidecar(exit_early: true)

    error = assert_raises(Backend::Error) { @backend.start_browser(sandbox, mode: :headless) }

    assert_match(/exited before it started.*refusing to start with token \[REDACTED\]/m, error.message)
    assert_not_includes error.message, TOKEN
    assert_nil state(sandbox)["browser"]
    assert_empty workspace(sandbox).children.select { |child| child.basename.to_s.start_with?("browser-") }
  end

  test "a sandbox that never booted here has no browser to start" do
    sandbox = SandboxDouble.new(session_id: SecureRandom.uuid, browser_launch: launch)

    error = assert_raises(Backend::Error) { @backend.start_browser(sandbox, mode: :headless) }

    assert_match(/has no local checkout/, error.message)
    assert @backend.stop_browser(sandbox)
  end

  private

  # A workspace as a boot leaves one, without booting anything: start_browser
  # needs the checkout directory and state.json.
  def booted_sandbox
    sandbox = SandboxDouble.new(session_id: SecureRandom.uuid, browser_launch: launch)
    workspace(sandbox).join("app").mkpath
    workspace(sandbox).join("state.json").write("{}")
    sandbox
  end

  def launch
    {
      token: TOKEN,
      app_url: "http://127.0.0.1:4100",
      capabilities: [ "testing" ],
      stop_at: 2.hours.from_now.change(usec: 0),
      recording: {
        url: "http://127.0.0.1:3000/activeagents/api/session_recordings/7/events", token: RECORDING_TOKEN,
        batch_events: 1000, batch_bytes: 1_048_576
      }
    }
  end

  # node_command becomes a wrapper around the fake, and browser_sidecar_path
  # a checkout holding the entrypoint unless +checkout+ is false, in which
  # case the entrypoint is installed where the package would be.
  def install_fake_sidecar(version: ActionAgent::VERSION, chromium: true, exit_early: false, checkout: true)
    flags = [ "--sidecar-version=#{version}", ("--no-chromium" unless chromium), ("--exit-early" if exit_early) ].compact
    wrapper = @tmp.join("node-#{SecureRandom.hex(3)}")
    wrapper.write("#!/bin/sh\nexec #{[ RbConfig.ruby, File.join(FIXTURES, "fake_browser_sidecar.rb"), *flags ].shelljoin} \"$@\"\n")
    wrapper.chmod(0o755)
    ActionAgent.node_command = wrapper.to_s

    package = checkout ? @tmp.join("browser-sidecar") : ActionAgent::BrowserSidecar.root.join("node_modules", "@activeagents", "browser-sidecar")
    package.join("bin").mkpath
    package.join(ActionAgent::BrowserSidecar::ENTRYPOINT).write("// the fake runs instead\n")
    ActionAgent.browser_sidecar_path = checkout ? package.to_s : nil
  end

  def workspace(sandbox)
    ActionAgent.local_sandbox_root.join(sandbox.session_id)
  end

  def state(sandbox)
    JSON.parse(workspace(sandbox).join("state.json").read)
  end

  def sidecar_record(sandbox)
    dir = workspace(sandbox).join(state(sandbox).dig("browser", "dir"))
    JSON.parse(dir.join("record.json").read)
  end

  def rpc(uri, token:)
    request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
    request["Authorization"] = "Bearer #{token}" if token
    request.body = JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list")
    Net::HTTP.new(uri.host, uri.port).start { |http| http.request(request) }
  end

  def assert_gone(*pids)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    pids.each do |pid|
      sleep 0.05 until process_gone?(pid) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert process_gone?(pid), "process #{pid} is still running"
    end
  end

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
end
