# frozen_string_literal: true

require "test_helper"

# The orchestrator's optional verbs: a backend that defines them is
# dispatched to, and one that does not reports it through #supports? and
# refuses the call with UnsupportedBackendError.
class SandboxOrchestratorVerbsTest < ActiveSupport::TestCase
  OPTIONAL_VERBS = %i[changed_files read_file start_browser stop_browser resume_boot].freeze

  # Implements every optional verb and records how it was called.
  class FullBackend
    class << self
      attr_accessor :calls
    end
    self.calls = []

    def create_sandbox(_session) = {}
    def status(_handle) = {}
    def terminate(_handle) = true
    def list_sandboxes = []
    def cleanup_expired = 0

    def changed_files(session)
      record(:changed_files, session)
      { base_commit: "a" * 40, files: [ { path: "app/models/widget.rb", status: "modified", mode: "100644" } ] }
    end

    def read_file(session, path)
      record(:read_file, session, path)
      "class Widget; end\n".b
    end

    def start_browser(session, mode:)
      record(:start_browser, session, mode)
      { mcp_url: "http://browser.test/mcp", mcp_token: "browser-token" }
    end

    def stop_browser(session)
      record(:stop_browser, session)
      true
    end

    def resume_boot(session, from:)
      record(:resume_boot, session, from)
      { container_name: "full-#{session}", url: "http://app.test", mcp_url: "http://app.test/mcp", mcp_token: "t" }
    end

    private

    def record(*call)
      self.class.calls << call
    end
  end

  def setup
    @original_backends = ActionAgent.sandbox_backends
    ActionAgent.sandbox_backends = { "full" => FullBackend.name }
    FullBackend.calls = []
  end

  def teardown
    ActionAgent.sandbox_backends = @original_backends
  end

  # Runs a browser without a window only.
  class HeadlessOnlyBackend < FullBackend
    def self.calls = FullBackend.calls

    def browser_modes = [ :headless ]
  end

  test "the engine's own backends support the optional verbs they implement" do
    mock = ActionAgent::SandboxOrchestrator.new(backend: "mock")
    OPTIONAL_VERBS.each { |verb| assert_not mock.supports?(verb), "mock should not claim #{verb}" }
    assert_empty mock.browser_modes

    local = ActionAgent::SandboxOrchestrator.new(backend: "local")
    OPTIONAL_VERBS.each do |verb|
      assert_equal %i[start_browser stop_browser].include?(verb), local.supports?(verb), "local and #{verb}"
    end
    assert_includes local.browser_modes, :headless
  end

  test "a backend that does not say which browser modes it runs is asked for either" do
    assert_equal %i[headless headed], ActionAgent::SandboxOrchestrator.new(backend: "full").browser_modes
  end

  test "a headed browser is refused on a backend that cannot show a window, before the backend is asked" do
    ActionAgent.sandbox_backends = { "headless_only" => HeadlessOnlyBackend.name }
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "headless_only")

    error = assert_raises(ActionAgent::SandboxOrchestrator::UnsupportedBackendError) { orchestrator.start_browser("s1", mode: :headed) }
    assert_match(/cannot show a browser window; start the browser headless/, error.message)
    assert_empty FullBackend.calls

    orchestrator.start_browser("s1", mode: :headless)
    assert_equal [ [ :start_browser, "s1", :headless ] ], FullBackend.calls
  end

  test "an unsupported verb is refused, naming the method a backend would implement" do
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "mock")

    error = assert_raises(ActionAgent::SandboxOrchestrator::UnsupportedBackendError) { orchestrator.changed_files("s1") }
    assert_match(/implements none of changed_files/, error.message)
    assert_raises(ActionAgent::SandboxOrchestrator::UnsupportedBackendError) { orchestrator.read_file("s1", "README.md") }
    assert_raises(ActionAgent::SandboxOrchestrator::UnsupportedBackendError) { orchestrator.start_browser("s1") }
    assert_raises(ActionAgent::SandboxOrchestrator::UnsupportedBackendError) { orchestrator.stop_browser("s1") }
    assert_raises(ActionAgent::SandboxOrchestrator::UnsupportedBackendError) { orchestrator.resume_boot("s1", from: "setup") }
  end

  test "a backend that implements the verbs supports them and is called with their arguments" do
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "full")

    OPTIONAL_VERBS.each { |verb| assert orchestrator.supports?(verb), verb }

    changes = orchestrator.changed_files("s1")
    assert_equal "a" * 40, changes[:base_commit]
    assert_equal [ "app/models/widget.rb" ], changes[:files].map { |file| file[:path] }
    assert_equal Encoding::BINARY, orchestrator.read_file("s1", "app/models/widget.rb").encoding
    assert_equal "http://browser.test/mcp", orchestrator.start_browser("s1", mode: :headed)[:mcp_url]
    assert orchestrator.stop_browser("s1")

    assert_equal [
      [ :changed_files, "s1" ],
      [ :read_file, "s1", "app/models/widget.rb" ],
      [ :start_browser, "s1", :headed ],
      [ :stop_browser, "s1" ]
    ], FullBackend.calls
  end

  test "a browser starts headless unless asked otherwise, and an unknown mode is refused" do
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "full")

    orchestrator.start_browser("s1")
    assert_raises(ArgumentError) { orchestrator.start_browser("s1", mode: :kiosk) }

    assert_equal [ [ :start_browser, "s1", :headless ] ], FullBackend.calls
  end

  test "resuming a boot answers in the shape a create does" do
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "full")

    result = orchestrator.resume_boot("s1", from: "db_prepare")

    assert_equal [ [ :resume_boot, "s1", "db_prepare" ] ], FullBackend.calls
    assert_equal "full-s1", result[:sandbox_id]
    assert_equal "full", result[:backend]
    assert_equal "http://app.test/mcp", result[:mcp_url]
    assert_equal "t", result[:mcp_token]
  end

  test "reading a path outside the checkout is refused before the backend is asked" do
    orchestrator = ActionAgent::SandboxOrchestrator.new(backend: "full")

    [ "/etc/passwd", "../outside", "app/../../outside", "", "app/\0name", nil, :README ].each do |path|
      assert_raises(ArgumentError, path.inspect) { orchestrator.read_file("s1", path) }
    end
    assert_empty FullBackend.calls

    orchestrator.read_file("s1", "app/..hidden/file.rb")
    assert_equal [ [ :read_file, "s1", "app/..hidden/file.rb" ] ], FullBackend.calls
  end
end
