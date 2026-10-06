# frozen_string_literal: true

require "test_helper"
require "mcp"
require "rbconfig"
require "tmpdir"
require "active_agent/providers/mcp_bridge"

# How `read_timeout:` bounds a `command:` server, against a real one.
#
# Unlike MCPBridgeTest, these run the gem's stdio transport: the bound depends on
# how that transport reads, which a stand-in client would hide. The server is a
# script that answers like any other, except that it never answers the request
# it is told to stall on.
class MCPBridgeReadTimeoutTest < ActiveSupport::TestCase
  TimeoutError = ActiveAgent::Providers::MCPBridge::TimeoutError

  STALLING_SERVER = File.expand_path("../fixtures/files/stalling_mcp_server.rb", __dir__)

  # The cache is process-global; see MCPBridgeTest.
  setup    { ActiveAgent::Providers::MCPToolCache.reset! }
  teardown { ActiveAgent::Providers::MCPToolCache.reset! }

  test "stops a server that sends notifications instead of answering a tool call" do
    with_stalling_server(stall_on: "tools/call", read_timeout: 0.5) do |bridge, pid_file|
      bridge.tools # connects first, so the time below is the call's alone

      started = now
      error   = assert_raises(TimeoutError) { finishing_within(10) { bridge.call("wait") } }

      assert_operator now - started, :<, 3, "notifications and pings must not extend the deadline"
      assert_kind_of Timeout::Error, error
      assert_includes error.message, %("stalling")
      assert_includes error.message, %(tools/call for "wait")
      assert_not running?(pid_file), "a server that misses its deadline must be stopped"
    end
  end

  test "stops a server that sends notifications instead of listing its tools" do
    with_stalling_server(stall_on: "tools/list", read_timeout: 0.5) do |bridge, pid_file|
      error = assert_raises(TimeoutError) { finishing_within(10) { bridge.tools } }

      assert_includes error.message, "tools/list"
      assert_not running?(pid_file), "a server that misses its deadline must be stopped"
    end
  end

  # The stopped connection cannot answer at all, so a second timeout, rather
  # than an error from that connection, shows a new process was reached.
  test "starts a server again after stopping it" do
    with_stalling_server(stall_on: "tools/call", read_timeout: 0.3) do |bridge, pid_file|
      bridge.tools
      stopped = File.read(pid_file)

      assert_raises(TimeoutError) { finishing_within(10) { bridge.call("wait") } }
      assert_raises(TimeoutError) { finishing_within(10) { bridge.call("wait") } }
      assert_not_equal stopped, File.read(pid_file)
    end
  end

  test "returns an answer that arrives within the timeout" do
    with_stalling_server(read_timeout: 5) do |bridge, _pid_file|
      assert_equal "done", finishing_within(10) { bridge.call("wait") }
    end
  end

  # A server that silently drops a method it does not know never answers the
  # probe, so the client waits out the probe's bound before it falls back to
  # `initialize`. The bound is shortened here to keep the tests fast.
  test "gives up on an unanswered discover probe after the gem's bound, not the read timeout" do
    stub_const(MCP::Client::Stdio, :DEFAULT_DISCOVER_PROBE_TIMEOUT, 0.3) do
      with_stalling_server(stall_on: "server/discover", silent: true, read_timeout: 5) do |bridge, _pid_file|
        started = now

        assert_equal %w[wait], finishing_within(10) { bridge.tools.pluck(:name) }
        assert_operator now - started, :<, 2.5, "the probe must give up after its own bound"
      end
    end
  end

  test "allows the handshake the probe's bound on top of the read timeout" do
    stub_const(MCP::Client::Stdio, :DEFAULT_DISCOVER_PROBE_TIMEOUT, 1) do
      with_stalling_server(stall_on: "server/discover", silent: true, read_timeout: 0.9) do |bridge, _pid_file|
        assert_equal %w[wait], finishing_within(10) { bridge.tools.pluck(:name) }
      end
    end
  end

  # An exchange runs on a thread of its own, so an exception that is not a
  # StandardError has to be handed back explicitly.
  test "raises an exception that is not a StandardError at once, not as a timeout" do
    stack_error = Class.new(Exception)
    bridge      = ActiveAgent::Providers::MCPBridge.new(nil)
    server      = ActiveAgent::Providers::MCPBridge::Server.new(
      name: "local", declaration: { command: "mcp-server", read_timeout: 5 }, client: Object.new
    )
    started = now

    assert_raises(stack_error) do
      finishing_within(10) { bridge.send(:answer_within_read_timeout, server, "tools/list") { raise stack_error } }
    end
    assert_operator now - started, :<, 1, "the exception must not wait out the read timeout"
  end

  private

  # Yields a bridge over STALLING_SERVER, and the file the server writes its pid
  # to. The bridge is closed afterwards, which stops the server.
  def with_stalling_server(read_timeout:, stall_on: nil, silent: false)
    Dir.mktmpdir do |dir|
      pid_file = File.join(dir, "server.pid")
      args     = [ STALLING_SERVER, pid_file, stall_on, ("silent" if silent) ].compact
      bridge   = ActiveAgent::Providers::MCPBridge.new(
        [ { name: "stalling", command: RbConfig.ruby, args:, read_timeout: } ], cache: false
      )

      yield bridge, pid_file
    ensure
      bridge&.close
    end
  end

  # Runs the block on a thread of its own and fails the test if it is still
  # running after `seconds`, so a bridge that never gives up fails the suite
  # rather than hanging it.
  def finishing_within(seconds, &block)
    runner = Thread.new do
      Thread.current.report_on_exception = false
      block.call
    end

    unless runner.join(seconds)
      runner.kill
      flunk "still waiting after #{seconds} seconds"
    end

    runner.value
  end

  def running?(pid_file)
    Process.kill(0, Integer(File.read(pid_file)))
    true
  rescue Errno::ESRCH
    false
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
