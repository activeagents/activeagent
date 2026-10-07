# frozen_string_literal: true

require "test_helper"

class SandboxClaudeLoginTest < ActiveSupport::TestCase
  def setup
    @saved = %i[claude_code_command claude_code_auth claude_code_login_timeout].index_with { |key| ActionAgent.public_send(key) }.merge(local_sandboxes_enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled), local_sandbox_root: ActionAgent.instance_variable_get(:@local_sandbox_root))
    @root = Pathname(Dir.mktmpdir("sandbox-login"))
    ActionAgent.local_sandboxes_enabled = true
    ActionAgent.local_sandbox_root = @root.to_s
    ActionAgent.claude_code_auth = :sandbox_login
    ActionAgent.claude_code_login_timeout = 10
    @sandbox = Struct.new(:session_id).new(SecureRandom.uuid)
    @workspace = @root.join(@sandbox.session_id)
    FileUtils.mkdir_p(@workspace.join("app"))
    command = @root.join("fake-claude")
    command.write(<<~'SCRIPT')
      #!/usr/bin/env ruby
      require "json"
      require "fileutils"
      config = ENV.fetch("CLAUDE_CONFIG_DIR")
      credential = File.join(config, ".credentials.json")
      case ARGV
      when ["auth", "login"]
        STDOUT.sync = true
        puts "https://claude.ai/oauth/authorize?client_id=fixture&state=synthetic"
        code = STDIN.gets.to_s.strip
        puts "echoed #{code} sk-ant-oat01-syntheticNeverPublish"
        exit 1 unless code == "single-use-fixture-code"
        File.write(credential, JSON.generate(authMethod: "claude.ai"))
      when ["auth", "status", "--json"]
        puts JSON.generate(loggedIn: File.exist?(credential), authMethod: File.exist?(credential) ? "claude.ai" : "none")
      when ["auth", "logout"]
        FileUtils.rm_f(credential)
      end
    SCRIPT
    command.chmod(0o700)
    ActionAgent.claude_code_command = command.to_s
    @backend = ActionAgent::LocalSandboxBackend.new
  end

  def teardown
    @backend&.claude_logout(@sandbox)
    @saved&.each { |key, value| ActionAgent.public_send("#{key}=", value) }
    FileUtils.rm_rf(@root)
  end

  test "a PTY login accepts one code without persisting output and verifies effective subscription authentication" do
    assert_equal "starting", @backend.start_claude_login(@sandbox)[:status]
    login = wait_for("awaiting_code")
    assert_match %r{\Ahttps://claude.ai/oauth/authorize}, login[:authorize_url]
    @backend.submit_claude_login_code(@sandbox, "single-use-fixture-code")
    assert_raises(ActionAgent::LocalSandboxBackend::Error) { @backend.submit_claude_login_code(@sandbox, "single-use-fixture-code") }
    assert wait_for("connected")[:logged_in]
    assert_equal 0o700, @workspace.join("claude").stat.mode & 0o777
    assert_equal 0o600, @workspace.join("claude/.credentials.json").stat.mode & 0o777
    @workspace.glob("**/*", File::FNM_DOTMATCH).select(&:file?).each do |file|
      refute_includes file.read, "single-use-fixture-code", file.to_s
      refute_includes file.read, "syntheticNeverPublish", file.to_s
    end
    @backend.claude_logout(@sandbox)
    refute @workspace.join("claude").exist?
    refute @workspace.join("claude-login").exist?
  end

  test "expiry and cancellation stop the waiting CLI and remove its pipe" do
    ActionAgent.claude_code_login_timeout = 1
    @backend.start_claude_login(@sandbox)
    wait_for("awaiting_code")
    wait_for("expired")
    assert eventually { !@workspace.join("claude-login/code.pipe").exist? }
    @backend.start_claude_login(@sandbox)
    wait_for("awaiting_code")
    pid = JSON.parse(@workspace.join("state.json").read).fetch("claude_login_pid")
    @backend.claude_logout(@sandbox)
    assert eventually { begin; Process.kill(0, pid); false; rescue Errno::ESRCH; true; end }
  end

  test "project API helpers and authentication variables cannot silently replace a subscription" do
    FileUtils.mkdir_p(@workspace.join("app/.claude"))
    [ { apiKeyHelper: "echo not-run" }, { env: { ANTHROPIC_API_KEY: "synthetic" } } ].each do |settings|
      @workspace.join("app/.claude/settings.json").write(settings.to_json)
      assert_raises(ActionAgent::LocalSandboxBackend::Error) { @backend.claude_login_status(@sandbox) }
    end
    env = @backend.send(:sandbox_login_environment, @workspace)
    assert_empty env.keys.grep(/\A(?:ANTHROPIC_|CLAUDE_CODE_OAUTH_TOKEN\z)/)
    assert_equal @workspace.join("claude-home").to_s, env["HOME"]
  end

  test "credential directories are excluded even when copied into a repository" do
    %w[claude/.credentials.json .claude/settings.json nested/claude-home/token nested/.credentials.json].each do |path|
      assert ActionAgent::SandboxCredentialPaths.protected?(path)
    end
    refute ActionAgent::SandboxCredentialPaths.protected?("app/agents/claude_agent.rb")
    assert_equal "[REDACTED]", ActionAgent::SecretScrubber.scrub("sk-ant-oat01-syntheticToken", [])
  end

  private

  def eventually
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  def wait_for(status)
    login = nil
    assert eventually { login = @backend.claude_login_status(@sandbox); login[:status] == status }, "expected #{status}, got #{login.inspect}"
    login
  end
end
