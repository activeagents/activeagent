# frozen_string_literal: true

require "test_helper"
require "socket"
require "tmpdir"
require "fileutils"

# The browser, for real. Starts the published Playwright MCP server the way
# the platform runs it (`npx @playwright/mcp --port …`), points the engine's
# client at it, and drives a static ticket page through the same tools the
# Conference Ticket Agent is given. Needs Node and a Chromium, so it runs only
# when asked:
#
#   PLAYWRIGHT_MCP_SMOKE=1 bin/test actionagent/test/playwright_mcp_smoke_test.rb
#
# PLAYWRIGHT_MCP_VERSION pins the package (default latest), PLAYWRIGHT_CHROMIUM
# names a browser executable when Playwright has not installed one.
class PlaywrightMCPSmokeTest < ActiveSupport::TestCase
  PAGE = File.expand_path("fixtures/files/conference_tickets.html", __dir__)
  STARTUP_TIMEOUT = 120 # seconds; the first run downloads the package

  def setup
    skip "set PLAYWRIGHT_MCP_SMOKE=1 to run the real Playwright MCP server" unless ENV["PLAYWRIGHT_MCP_SMOKE"] == "1"

    # The suite stubs the network (WebMock, with VCR answering what it does
    # not stub); this test's whole point is a real server on localhost.
    VCR.turn_off!(ignore_cassettes: true)
    WebMock.disable_net_connect!(allow_localhost: true)
    @port = free_port
    # Snapshots are written as files and linked from each result; keep them
    # out of the repository and name them absolutely so the test can read them.
    @output_dir = Dir.mktmpdir("playwright-mcp-smoke")
    command = [
      "npx", "-y", "@playwright/mcp@#{ENV.fetch('PLAYWRIGHT_MCP_VERSION', 'latest')}",
      "--port", @port.to_s, "--host", "127.0.0.1",
      "--headless", "--isolated", "--no-sandbox", "--allow-unrestricted-file-access",
      "--output-dir", @output_dir, "--file-paths", "absolute"
    ]
    command += [ "--executable-path", ENV["PLAYWRIGHT_CHROMIUM"] ] if ENV["PLAYWRIGHT_CHROMIUM"].present?
    @pid = Process.spawn(*command, out: File::NULL, err: File::NULL, pgroup: true)
    wait_for_server
    # The server answers only the host it was started for (`localhost` by
    # default; `--allowed-hosts` widens it) and refuses other Host headers
    # with a 403, so the client addresses it the same way.
    @client = ActionAgent::PlaywrightMCPClient.new(url: "http://localhost:#{@port}/mcp")
  end

  def teardown
    WebMock.disable_net_connect!
    VCR.turn_on!
    if @pid
      begin
        Process.kill("TERM", -@pid)
        Process.wait(@pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    FileUtils.remove_entry(@output_dir) if @output_dir && File.directory?(@output_dir)
  end

  test "the server offers the browser tools the agent is given" do
    names = @client.list_tools.map { |tool| tool[:name] }

    %w[browser_navigate browser_snapshot browser_click browser_type].each do |name|
      assert_includes names, name
    end
  end

  test "the browser reaches a ticket page and reads the registration form" do
    result = @client.call_tool("browser_navigate", { "url" => "file://#{PAGE}" })

    assert_not result[:is_error], result[:text]
    assert_match(/Page Title: Example Ruby Conference/, result[:text])
    snapshot = snapshot_text(result[:text])
    assert_match(/Register/, snapshot)
    assert_match(/Card number/, snapshot)
    assert_match(/Both days/, snapshot)
  end

  private

  # The server writes the page snapshot to a file and links it from the
  # result; the dashboard's toolbox inlines it the same way
  # (AgentToolbox#inline_snapshot).
  SNAPSHOT_LINK = /\[Snapshot\]\(([^)]+)\)/

  def snapshot_text(text)
    match = SNAPSHOT_LINK.match(text)
    assert match, "expected a snapshot link in: #{text}"
    path = match[1]
    path = File.join(@output_dir, path) unless path.start_with?("/")
    File.read(path)
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def wait_for_server
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STARTUP_TIMEOUT
    loop do
      begin
        TCPSocket.new("127.0.0.1", @port).close
        return
      rescue Errno::ECONNREFUSED
        _, status = Process.waitpid2(@pid, Process::WNOHANG)
        flunk "Playwright MCP exited before listening (#{status})" if status
        flunk "Playwright MCP did not listen on #{@port} within #{STARTUP_TIMEOUT}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.5
      end
    end
  end
end
