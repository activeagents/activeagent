# frozen_string_literal: true

require "test_helper"

# Codex sessions on the :local backend: the process they start, what they
# are given (a key or this machine's own login, the sandbox's browser), and
# what they are not.
class CodexBackendTest < ActiveSupport::TestCase
  Backend = ActionAgent::LocalSandboxBackend
  CONFIG = %i[codex_command claude_code_auth codex_auth].freeze
  SandboxDouble = Struct.new(:session_id, :checkout_spec)
  CodeSessionDouble = Struct.new(:id, :runner, :prompt, :model, :turn_index, :resume_session_id, keyword_init: true)
  THREAD = "0199f2c4-6a1b-7c3d-9e8f-0a1b2c3d4e5f"

  def setup
    @saved = CONFIG.index_with { |name| ActionAgent.public_send(name) }.merge(
      local_sandboxes_enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled),
      local_sandbox_root: ActionAgent.instance_variable_get(:@local_sandbox_root)
    )
    @root = Dir.mktmpdir("codex-backend")
    ActionAgent.local_sandboxes_enabled = true
    ActionAgent.local_sandbox_root = @root
    ActionAgent.codex_command = "codex"
    # Claude Code's mode is no business of a Codex session's.
    ActionAgent.claude_code_auth = :local_login
    ActionAgent.codex_auth = :api_key
    Backend.reset_codex_login_status!
  end

  def teardown
    @saved.each { |name, value| ActionAgent.public_send("#{name}=", value) }
    Backend.reset_codex_login_status!
    FileUtils.rm_rf(@root)
  end

  test "Codex receives its own credentials and config with a stdin prompt and bounded permissions" do
    sandbox, workspace = checkout
    session = CodeSessionDouble.new(id: 1, runner: "codex", prompt: "A private prompt", model: "test-model")

    captured = run_turn(sandbox, session)

    assert_equal "codex", captured[:runner]
    assert_equal [ "codex", "exec", "--json", "--sandbox", "workspace-write",
      "--config", 'approval_policy="never"', "--color", "never", "--model", "test-model", "-" ], captured[:argv]
    assert_not_includes captured[:argv], session.prompt
    assert_equal "sk-proj-syntheticFixture", captured[:env]["CODEX_API_KEY"]
    assert_equal workspace.join("codex").to_s, captured[:env]["CODEX_HOME"]
    assert_not captured[:env].key?("ANTHROPIC_API_KEY")
    assert_not captured[:env].key?("CLAUDE_CONFIG_DIR")
    assert_not captured[:env].key?(Backend::BROWSER_TOKEN_ENV), "no browser running, no token"
    assert_equal [ "sk-proj-syntheticFixture" ], captured[:secrets]
    # `codex exec` takes no system prompt, so the note goes in on stdin.
    assert captured[:prompt].start_with?("<dashboard-note>\n#{Backend::CLAUDE_SYSTEM_NOTE}\n</dashboard-note>\n\n"), captured[:prompt]
    assert captured[:prompt].end_with?("A private prompt")
  end

  test "with no key stored a Codex session is refused before anything starts" do
    sandbox, _workspace = checkout(key: nil)

    error = assert_raises(Backend::Error) { run_turn(sandbox, CodeSessionDouble.new(id: 2, runner: "codex", prompt: "Hello")) }
    assert_match(/Codex is not connected: connect an OpenAI API key/, error.message)
  end

  test "host Codex configuration and credentials cannot enter another workspace" do
    env = Backend.sanitized_environment("PATH" => "/bin", "CODEX_HOME" => "/private/config",
      "CODEX_API_KEY" => "sk-fixture", "CODEX_THREAD_ID" => "host-thread", "OPENAI_BASE_URL" => "https://elsewhere.test")
    assert_equal({ "PATH" => "/bin" }, env)
  end

  test "a later Codex turn resumes the first turn's thread, its sandbox set as configuration" do
    session = CodeSessionDouble.new(turn_index: 1, resume_session_id: THREAD)
    assert_equal [ "codex", "exec", "resume", "--json", "--config", 'sandbox_mode="workspace-write"',
      "--config", 'approval_policy="never"', THREAD, "-" ],
      Backend.new.send(:codex_argv, session).tap { |argv| argv[0] = File.basename(argv[0]) }

    flag = CodeSessionDouble.new(turn_index: 1, resume_session_id: "--last")
    assert_raises(Backend::Error) { Backend.new.send(:codex_argv, flag) }
  end

  test "Codex rejects flag-like model names before starting a process" do
    session = CodeSessionDouble.new(model: "--dangerously-bypass-approvals-and-sandbox")
    assert_raises(Backend::Error) { Backend.new.send(:codex_argv, session) }
  end

  test "with the sandbox's browser running, a Codex turn is given it as configuration and the token in its environment, revoked after" do
    sandbox, _workspace = checkout
    token = "cl_codexTurnToken0123456789abcdefghijklmnop"
    minted = []
    revoked = []
    fake = Struct.new(:token, :mcp_url).new(token, "http://127.0.0.1:4999/mcp")
    fake.define_singleton_method(:revoke!) { revoked << token }
    sandbox.define_singleton_method(:browser_running?) { true }
    session = CodeSessionDouble.new(id: 7, runner: "codex", prompt: "Open the page", turn_index: 2, resume_session_id: THREAD)

    captured = ActionAgent::BrowserClientToken.stub(:mint, ->(_sandbox, label:) { minted << label; fake }) do
      run_turn(sandbox, session)
    end

    assert_equal [ "Codex · turn 3" ], minted
    argv = captured[:argv]
    url = argv.index('mcp_servers.browser.url="http://127.0.0.1:4999/mcp"')
    variable = argv.index('mcp_servers.browser.bearer_token_env_var="ACTION_AGENT_BROWSER_TOKEN"')
    assert url && variable, argv.inspect
    assert_equal [ "--config", "--config" ], [ argv[url - 1], argv[variable - 1] ]
    assert_equal THREAD, argv[-2], "the thread id stays ahead of the stdin marker"
    assert_not(argv.any? { |argument| argument.include?(token) }, "the token is never on the command line")
    assert_equal token, captured[:env]["ACTION_AGENT_BROWSER_TOKEN"]
    assert_includes captured[:secrets], token, "the token is scrubbed from the session's output"
    assert_equal [ token ], revoked
  end

  test "a browser that cannot mint a token leaves the Codex turn without one rather than failing it" do
    sandbox, _workspace = checkout
    sandbox.define_singleton_method(:browser_running?) { true }
    captured = ActionAgent::BrowserClientToken.stub(:mint, ->(*) { raise ActionAgent::BrowserClientToken::Error, "HTTP 503" }) do
      run_turn(sandbox, CodeSessionDouble.new(id: 8, runner: "codex", prompt: "Hello"))
    end

    assert_not_includes captured[:argv].join(" "), "mcp_servers"
    assert_not captured[:env].key?(Backend::BROWSER_TOKEN_ENV)
  end

  test ":local_login runs Codex on this machine's own login: no key, no Codex home of its own, none of the user's configuration" do
    ActionAgent.codex_auth = :local_login
    sandbox, _workspace = checkout(key: nil)

    captured = run_turn(sandbox, CodeSessionDouble.new(id: 3, runner: "codex", prompt: "Hello"))

    assert_includes captured[:argv], "--ignore-user-config"
    assert_not captured[:env].key?("CODEX_API_KEY")
    assert_not captured[:env].key?("CODEX_HOME"), "codex finds the user's own ~/.codex through HOME"
    assert_equal [], captured[:secrets]

    resumed = run_turn(sandbox, CodeSessionDouble.new(id: 4, runner: "codex", prompt: "More", turn_index: 1, resume_session_id: THREAD))
    assert_equal [ "exec", "resume" ], resumed[:argv][1, 2]
    assert_includes resumed[:argv], "--ignore-user-config"
    assert_equal [ THREAD, "-" ], resumed[:argv].last(2)
  end

  test "codex_login_status keeps whether this machine is logged in and how, and trusts a failing CLI with nothing" do
    system("true")
    ok = $?
    system("false")
    failed = $?

    assert_equal({ logged_in: true, auth_method: "ChatGPT", api_provider: nil }, Backend.parse_codex_login_status("Logged in using ChatGPT\n", ok))
    assert_equal({ logged_in: true, auth_method: "API key", api_provider: nil }, Backend.parse_codex_login_status("Logged in using an API key\n", ok))
    assert_equal Backend::LOGGED_OUT, Backend.parse_codex_login_status("Not logged in\n", failed)
    assert_equal Backend::LOGGED_OUT, Backend.parse_codex_login_status("Logged in using ChatGPT\n", failed)
    assert_equal Backend::LOGGED_OUT, Backend.parse_codex_login_status("", ok)
    assert_equal Backend::LOGGED_OUT, Backend.parse_codex_login_status("Logged in using ChatGPT\n", nil)

    script = File.join(@root, "codex")
    File.write(script, "#!/bin/sh\nif [ \"$1 $2\" = \"login status\" ]; then echo 'Logged in using ChatGPT'; exit 0; fi\nexit 2\n")
    File.chmod(0o755, script)
    ActionAgent.codex_command = script
    Backend.reset_codex_login_status!
    assert_equal({ logged_in: true, auth_method: "ChatGPT" }, Backend.codex_login_status.slice(:logged_in, :auth_method))

    File.write(script, "#!/bin/sh\necho 'Not logged in'; exit 1\n")
    assert Backend.codex_login_status[:logged_in], "a logged-in answer is cached for a while"
    Backend.reset_codex_login_status!
    assert_not Backend.codex_login_status[:logged_in]
  end

  test "codex_auth accepts :api_key and :local_login only" do
    ActionAgent.codex_auth = "local_login"
    assert_equal :local_login, ActionAgent.codex_auth

    error = assert_raises(ArgumentError) { ActionAgent.codex_auth = :sandbox_login }
    assert_match(/must be :api_key or :local_login/, error.message)
    assert_equal :local_login, ActionAgent.codex_auth
  end

  private

  # A booted checkout as the backend sees it, whose owner connected +key+.
  def checkout(key: "sk-proj-syntheticFixture")
    id = SecureRandom.uuid
    workspace = Pathname(@root).join(id)
    FileUtils.mkdir_p(workspace.join("app"))
    sandbox = SandboxDouble.new(id, nil)
    sandbox.define_singleton_method(:runtime_environment) do |runner:|
      raise "wrong runner" unless runner == "codex"

      key ? { "CODEX_API_KEY" => key } : {}
    end
    [ sandbox, workspace ]
  end

  # Runs +session+ in +sandbox+ through a backend whose process start is
  # captured instead of made.
  def run_turn(sandbox, session)
    backend = Backend.new
    captured = nil
    backend.define_singleton_method(:run_claude) do |path, code, argv, env, secrets, runner:, prompt: nil, &_on_event|
      captured = { path: path, code: code, argv: argv, env: env, secrets: secrets, runner: runner, prompt: prompt }
    end
    backend.run_code_session(sandbox, session)
    captured
  end
end
