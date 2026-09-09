# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The code-on-incus backend is where a code session stops being a database
# row and becomes a container, a profile and a token on disk. Nothing here
# runs coi: a recording runner stands in for it, so the assertions are about
# the two things that actually matter — the exact profile a session runs
# under, and the fact that a GitHub token reaches the container through a
# 0600 file and coi's [env_commands] rather than through argv, a transcript
# or an error message.
class ActionAgentCodeOnIncusBackendTest < ActiveSupport::TestCase
  Backend = ActionAgent::CodeOnIncusBackend

  # Deliberately distinctive: every assertion below that this string is
  # absent would pass by accident against a short or common value.
  TOKEN = "ghp_liveTokenThatMustNeverEscapeTheSandbox"

  # Records what the backend would have run instead of running it. It takes
  # no chdir because the backend never passes one — a backend that started
  # to would fail here rather than pass silently.
  class FakeRunner
    def self.result(stdout: "", stderr: "", exit_code: 0, timed_out: false)
      ActionAgent::CommandRunner::Result.new(
        stdout: stdout, stderr: stderr, exit_code: exit_code, duration_ms: 12, timed_out: timed_out
      )
    end

    attr_reader :calls

    # The block answers one recorded call with a Result, or nil to let it
    # succeed with no output.
    def initialize(&answer)
      @calls = []
      @answer = answer
    end

    def call(argv, env: {}, stdin: nil, timeout: nil)
      recorded = { argv: Array(argv).map(&:to_s), env: env.to_h, stdin: stdin, timeout: timeout }
      @calls << recorded
      @answer&.call(recorded) || self.class.result
    end

    def argvs = calls.map { |recorded| recorded[:argv] }

    def coi(verb) = calls.select { |recorded| recorded[:argv].first(2) == [ "coi", verb ] }
  end

  def setup
    @root = Dir.mktmpdir("action-agent-code-sessions")
    # ActionAgent.github_token_for falls back to ENV["GITHUB_TOKEN"] in a
    # single-tenant install, and a developer's shell usually has one. Left
    # set, the operator's own token would decide what a transcript masks
    # instead of the token this session was launched with.
    @environment_token = ENV.delete("GITHUB_TOKEN")
    @runner = FakeRunner.new
    @session = session_with
  end

  def teardown
    ENV["GITHUB_TOKEN"] = @environment_token if @environment_token
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def session_with(**attributes)
    ActionAgent::CodeSession.create!(
      { tool: "claude_code", backend: "code_on_incus", task: "Add the missing tool" }.merge(attributes)
    )
  end

  def backend(runner: @runner, **overrides)
    Backend.new(
      runner: runner,
      config: ActiveSupport::OrderedOptions.new.merge!(
        {
          binary: "coi", ssh_target: nil, state_dir: @root, base_profile: "hardened",
          image: nil, cpu_limit: "4", memory_limit: "8GB", allowlist: [ "github.com" ]
        }.merge(overrides)
      )
    )
  end

  def state_dir(session = @session) = File.join(@root, session.session_id)

  def workspace_dir(session = @session) = File.join(state_dir(session), "workspace")

  def profile_path(session = @session) = File.join(state_dir(session), "profile", "config.toml")

  def profile_for(session = @session) = File.read(profile_path(session))

  # --- launch -------------------------------------------------------------

  test "launch writes the profile, the brief, the prompt and a 0600 token file" do
    session = session_with(github_access: "write", task: "Push a branch")

    result = backend.launch(session, brief: { "needs" => [ { "title" => "Give the agent find_records" } ] }, github_token: TOKEN)

    assert_path_exists profile_path(session)
    assert_path_exists File.join(state_dir(session), "BRIEF.md")
    assert_path_exists File.join(state_dir(session), "PROMPT.md")
    assert_equal "Push a branch", File.read(File.join(state_dir(session), "PROMPT.md"))
    assert_includes File.read(File.join(state_dir(session), "BRIEF.md")), "find_records"

    secrets = File.join(state_dir(session), "secrets", "github_token")

    assert_path_exists secrets
    assert_equal TOKEN, File.read(secrets)
    assert_equal 0o600, File.stat(secrets).mode & 0o777, "the token file must not be readable by anyone else"

    assert_equal "action-agent-#{session.session_id.delete("-")[0, 12]}", result[:container_id]
    assert_equal workspace_dir(session), result[:workspace_path]
    assert_equal "ready", result[:status]
  end

  # No token given, no token file: a session with no GitHub access has
  # nothing to leave behind.
  test "launch writes no token file when it was handed no token" do
    backend.launch(@session, brief: {})

    assert_not File.exist?(File.join(state_dir, "secrets", "github_token"))
  end

  test "the profile pins the tool, the network mode, the mounts and the limits" do
    session = session_with(network_mode: "allowlist", github_access: "read", repository: "acme/app", branch: "feature/x-1")
    backend.launch(session, github_token: TOKEN)
    profile = profile_for(session)

    assert_includes profile, %(inherits = "hardened")

    # coi drives Claude Code itself, and nobody is inside the container to
    # answer a permission prompt.
    assert_includes profile, "[tool]"
    assert_includes profile, %(name = "claude")
    assert_includes profile, %(permission_mode = "bypass")

    assert_includes profile, %(mode = "allowlist"), "the session's network mode, not the backend's default"
    assert_includes profile, %(allowlist = [ "github.com" ])

    assert_includes profile, "[mounts]"
    assert_includes profile, %("/workspace" = { path = "#{workspace_dir(session)}", readonly = false })
    assert_includes profile, %("/brief" = { path = "#{state_dir(session)}", readonly = true })

    assert_includes profile, "[limits]"
    assert_includes profile, %(cpu_limit = "4")
    assert_includes profile, %(memory_limit = "8GB")
    assert_includes profile, %(timeout = "#{ActionAgent.code_session_limits[:run_timeout_seconds]}")

    assert_includes profile, "[security]"
    assert_includes profile, %(workspace_secret_masking = true)
    assert_includes profile, %(auto_kill_on = "CRITICAL")
  end

  # The value stays in the 0600 file; only the command that reads it is in
  # the profile, and only for a session that was given GitHub access.
  test "env_commands read the github token from its file, and only with github access" do
    session = session_with(github_access: "write")
    backend.launch(session, github_token: TOKEN)
    profile = profile_for(session)
    token_file = File.join(state_dir(session), "secrets", "github_token")

    assert_includes profile, "[env_commands]"
    # 2>/dev/null so a session granted access whose owner configured no token
    # gets an empty variable and an anonymous clone, not an error on every
    # command the container runs.
    assert_includes profile, %(GH_TOKEN = "cat #{token_file} 2>/dev/null")
    assert_includes profile, %(GITHUB_TOKEN = "cat #{token_file} 2>/dev/null")
    # The coding agent's own provider key travels the same way.
    assert_includes profile, "ANTHROPIC_API_KEY = "

    backend.launch(@session)

    assert_not_includes profile_for, "GH_TOKEN"
    assert_includes profile_for, "ANTHROPIC_API_KEY = "
  end

  # The switch is what the session may do, not whether a token was actually
  # resolved: a session granted access but handed none still names GH_TOKEN,
  # and its env command finds no file to read. That is the documented
  # degradation — the clone script tests GH_TOKEN before using it — but it
  # is worth pinning, because it is the case where the profile promises a
  # credential the launch never wrote.
  test "a session granted github access but handed no token still names GH_TOKEN" do
    session = session_with(github_access: "read")

    backend.launch(session)

    assert_includes profile_for(session), "GH_TOKEN = "
    assert_not File.exist?(File.join(state_dir(session), "secrets", "github_token"))
    assert_includes Backend::CLONE_SCRIPT, %(if [ -n "${GH_TOKEN:-}" ]; then)
  end

  # The whole point of the [env_commands] indirection: `ps` on the host, a
  # shell history and the profile itself must all be safe to read.
  test "the token never reaches argv or the profile" do
    session = session_with(github_access: "write", repository: "acme/app")

    backend.launch(session, github_token: TOKEN)

    assert @runner.calls.any?, "the clone should have been attempted, so there is argv to check"
    @runner.argvs.flatten.each do |part|
      assert_not_includes part, TOKEN, "the token reached argv: #{part.inspect}"
    end
    profile_for(session).each_line do |line|
      assert_not_includes line, TOKEN, "the token reached the profile: #{line.inspect}"
    end
  end

  # --- clone --------------------------------------------------------------

  test "a repository is cloned by one coi run and travels as an env entry rather than in the script" do
    session = session_with(repository: "acme/app", branch: "feature/x-1")

    backend.launch(session)

    assert_equal 1, @runner.calls.size
    assert_equal(
      [ "coi", "run", "--workspace", workspace_dir(session), "--", "sh", "-c", Backend::CLONE_SCRIPT ],
      @runner.calls.first[:argv]
    )
    assert_equal({ "COI_CONFIG" => profile_path(session) }, @runner.calls.first[:env])

    # `acme/app; rm -rf /` has to be a repository that fails to clone, not a
    # command, so nothing about it is interpolated into the script.
    assert_not_includes Backend::CLONE_SCRIPT, "acme/app"
    assert_not_includes Backend::CLONE_SCRIPT, "feature/x-1"
    assert_includes profile_for(session), %(ACTIVE_AGENT_REPOSITORY = "acme/app")
    assert_includes profile_for(session), %(ACTIVE_AGENT_BRANCH = "feature/x-1")
  end

  test "a session with no repository clones nothing" do
    backend.launch(@session)

    assert_empty @runner.calls
    assert_not_includes profile_for, "ACTIVE_AGENT_REPOSITORY"
  end

  # git prints the URL it failed on, and with a credential helper that URL
  # can carry the token — so the failure has to be masked before it becomes
  # an error message the dashboard stores and renders.
  test "a clone that fails raises LaunchError with the token masked out" do
    session = session_with(repository: "acme/app", github_access: "write")
    runner = FakeRunner.new do
      FakeRunner.result(exit_code: 128, stderr: "fatal: could not read from https://x-access-token:#{TOKEN}@github.com/acme/app")
    end

    error = assert_raises(Backend::LaunchError) { backend(runner: runner).launch(session, github_token: TOKEN) }

    assert_not_includes error.message, TOKEN
    assert_includes error.message, "[redacted]"
    assert_includes error.message, "Could not clone acme/app"
  end

  # --- run ----------------------------------------------------------------

  test "run drives claude code through coi's own prompt-file path" do
    backend.launch(@session)
    @runner.calls.clear

    result = backend.run(@session, prompt: "Add the missing tool and cover it with a test")

    assert_equal 1, @runner.calls.size
    assert_equal(
      [ "coi", "run", "--workspace", workspace_dir, "--prompt-file", File.join(state_dir, "PROMPT.md") ],
      @runner.calls.first[:argv]
    )
    assert_equal "Add the missing tool and cover it with a test", File.read(File.join(state_dir, "PROMPT.md"))
    assert_equal 0, result[:exit_code]
  end

  test "a session that names a model passes it to coi" do
    @session.update!(model: "claude-sonnet-4-5")
    backend.run(@session, prompt: "Go")

    assert_equal(
      [ "coi", "run", "--workspace", workspace_dir, "--prompt-file", File.join(state_dir, "PROMPT.md"),
        "--model", "claude-sonnet-4-5" ],
      @runner.calls.first[:argv]
    )
  end

  # Everything but Claude Code is a plain command inside the container, from
  # the catalog's headless_command — which is why the catalog marks them
  # experimental. The prompt is read at its mounted path, not the host's.
  test "run drives codex as a plain command against the mounted prompt" do
    @session.update!(tool: "codex")

    backend.run(@session, prompt: "Go")

    assert_equal(
      [ "coi", "run", "--workspace", workspace_dir, "--", "codex", "exec", "--full-auto", "@/brief/PROMPT.md" ],
      @runner.calls.first[:argv]
    )
  end

  # pi has no headless mode here, so a run request is an error rather than a
  # command that would sit waiting for a person who is not attached.
  test "run refuses an interactive-only tool" do
    @session.update!(tool: "pi")

    error = assert_raises(Backend::RunError) { backend.run(@session, prompt: "Go") }

    assert_match(/cannot be run without attaching/, error.message)
    assert_empty @runner.calls, "nothing should have been started"
  end

  # --- transcript ---------------------------------------------------------

  # A coding agent that echoes its environment would otherwise put the token
  # straight into the transcript the dashboard renders.
  test "the transcript masks the token the session was launched with" do
    session = session_with(github_access: "write")
    runner = FakeRunner.new { FakeRunner.result(stdout: "GH_TOKEN=#{TOKEN}\ndone") }
    incus = backend(runner: runner)
    incus.launch(session, github_token: TOKEN)

    transcript = incus.run(session, prompt: "Go")[:transcript]

    assert_not_includes transcript, TOKEN
    assert_includes transcript, "GH_TOKEN=[redacted]"
  end

  test "the transcript carries stderr after stdout so a failure says why it stopped" do
    runner = FakeRunner.new { FakeRunner.result(stdout: "working", stderr: "boom", exit_code: 1) }

    result = backend(runner: runner).run(@session, prompt: "Go")

    assert_equal "working\n--- stderr ---\nboom", result[:transcript]
    assert_equal 1, result[:exit_code]
  end

  # A run killed at the timeout exits 124 with whatever it had printed, which
  # reads as a plain failure unless the transcript says what happened.
  test "a timed-out run is reported with the timeout it hit" do
    runner = FakeRunner.new { FakeRunner.result(stdout: "half done", exit_code: 124, timed_out: true) }

    result = backend(runner: runner).run(@session, prompt: "Go")

    assert_includes result[:transcript], "half done"
    assert_includes result[:transcript], "[timed out after #{ActionAgent.code_session_limits[:run_timeout_seconds]}s]"
    assert_equal 124, result[:exit_code]
  end

  test "token counts are parsed when the tool printed them" do
    runner = FakeRunner.new { FakeRunner.result(stdout: "Done.\nInput tokens: 1,234\nOutput tokens: 56\n") }

    result = backend(runner: runner).run(@session, prompt: "Go")

    assert_equal 1_234, result[:input_tokens]
    assert_equal 56, result[:output_tokens]
  end

  # Most tools print nothing about usage, and nil is a normal answer: a zero
  # here would be recorded as a real measurement.
  test "token counts are nil when the tool printed none" do
    result = backend.run(@session, prompt: "Go")

    assert_nil result[:input_tokens]
    assert_nil result[:output_tokens]
  end

  # --- terminate ----------------------------------------------------------

  # A container that refused to stop leaks compute; a token left on disk
  # leaks access, so the return value follows the state directory.
  test "terminate shuts the container down and removes the state directory" do
    backend.launch(@session, github_token: TOKEN)

    assert_path_exists state_dir

    incus = backend
    @runner.calls.clear

    assert incus.terminate(@session)
    assert_equal [ [ "coi", "shutdown" ] ], @runner.argvs
    assert_not File.exist?(state_dir), "the secrets go with the state directory"
  end

  test "a container that will not shut down is killed" do
    runner = FakeRunner.new do |call|
      FakeRunner.result(exit_code: 1, stderr: "still running") if call[:argv] == [ "coi", "shutdown" ]
    end
    incus = backend(runner: runner)
    incus.launch(@session)

    assert incus.terminate(@session)
    assert_equal 1, runner.coi("kill").size
    assert_not File.exist?(state_dir)
  end

  # Over ssh the state lives on the other host, so "gone" is what the remote
  # rm reports: a failed removal must not read as a clean termination.
  test "terminate is false when the state directory could not be removed" do
    runner = FakeRunner.new do |call|
      FakeRunner.result(exit_code: 1, stderr: "permission denied") if call[:argv].first == "rm"
    end

    assert_not backend(runner: runner, ssh_target: "coi@incus-host").terminate(@session)
    assert_equal [ "rm", "-rf", state_dir ], runner.calls.last[:argv]
  end

  # --- attach and remote writes -------------------------------------------

  test "attach_command names the profile through COI_CONFIG" do
    command = backend.attach_command(@session)

    assert_equal "COI_CONFIG=#{profile_path} coi attach", command
  end

  test "attach_command is an ssh invocation when coi runs on another host" do
    command = backend(ssh_target: "coi@incus-host").attach_command(@session)

    assert command.start_with?("ssh -t coi@incus-host "), command
    # ssh hands its arguments to a login shell that re-splits them, so the
    # whole invocation is escaped for that shell rather than passed raw.
    assert_includes command, "COI_CONFIG\\=#{profile_path}"
    assert_includes command, "coi\\ attach"
  end

  # ssh concatenates its arguments into one command string the remote shell
  # re-splits, so a file written through argv would be visible in `ps` on the
  # remote host. The content goes on standard input instead.
  test "over ssh a file is written from stdin rather than from argv" do
    session = session_with(github_access: "write")
    runner = FakeRunner.new
    backend(runner: runner, ssh_target: "coi@incus-host").launch(session, github_token: TOKEN)

    writes = runner.calls.select { |call| call[:argv].first == "sh" }

    assert writes.any?, "the profile and the secrets should be written through a remote shell"
    assert writes.all? { |call| call[:argv][1] == "-c" }

    profile_write = writes.find { |call| call[:stdin].to_s.include?(%(inherits = "hardened")) }

    assert profile_write, "the profile should travel on stdin"
    assert_includes profile_write[:argv][2], "cat > "
    assert writes.any? { |call| call[:stdin] == TOKEN }, "the token should travel on stdin"

    runner.argvs.flatten.each { |part| assert_not_includes part, TOKEN }
  end

  # --- profile escaping ---------------------------------------------------

  # A value with a quote in it would otherwise close its own string and turn
  # the rest of the line into TOML syntax.
  test "profile_toml escapes a quote and a backslash inside a value" do
    profile = backend(image: "a\"b\\c").profile_toml(@session)
    line = profile[/^image = (.+)$/, 1]

    assert_equal 'image = "a\"b\\\\c"', profile[/^image = .+$/]
    assert_match(/\A"(?:[^"\\]|\\.)*"\z/, line, "the value must still be one closed TOML basic string")
  end

  # The model is not a profile value: it is one argv element, which is what
  # keeps a name with a quote in it out of both the TOML and any shell.
  test "a model with a quote in it travels as one argv element and never reaches the profile" do
    @session.update!(model: "a\"b\\c")

    backend.run(@session, prompt: "Go")

    assert_equal "a\"b\\c", @runner.calls.first[:argv].last
    assert_not_includes backend.profile_toml(@session), "a\"b"
  end
end
