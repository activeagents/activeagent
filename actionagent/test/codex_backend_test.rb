# frozen_string_literal: true

require "test_helper"

class CodexBackendTest < ActiveSupport::TestCase
  Backend = ActionAgent::LocalSandboxBackend

  test "Codex receives its own credentials and config with a stdin prompt and bounded permissions" do
    original = %i[codex_command claude_code_auth].index_with { |name| ActionAgent.public_send(name) }.merge(
      local_sandboxes_enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled),
      local_sandbox_root: ActionAgent.instance_variable_get(:@local_sandbox_root)
    )
    Dir.mktmpdir("codex-backend") do |directory|
      ActionAgent.local_sandboxes_enabled = true
      ActionAgent.local_sandbox_root = directory
      ActionAgent.codex_command = "codex"
      ActionAgent.claude_code_auth = :local_login
      id = SecureRandom.uuid
      workspace = Pathname(directory).join(id)
      FileUtils.mkdir_p(workspace.join("app"))
      sandbox = Struct.new(:session_id, :checkout_spec).new(id, nil)
      sandbox.define_singleton_method(:runtime_environment) do |runner:|
        raise "wrong runner" unless runner == "codex"

        { "CODEX_API_KEY" => "sk-proj-syntheticFixture" }
      end
      session = Struct.new(:id, :runner, :prompt, :model).new(1, "codex", "A private prompt", "test-model")
      backend = Backend.new
      captured = nil
      backend.define_singleton_method(:run_claude) do |path, code, argv, env, secrets, runner:, &on_event|
        captured = { path: path, code: code, argv: argv, env: env, secrets: secrets, runner: runner }
      end
      backend.run_code_session(sandbox, session)

      assert_equal "codex", captured[:runner]
      assert_equal [ "codex", "exec", "--json", "--ephemeral", "--sandbox", "workspace-write",
        "--config", 'approval_policy="never"', "--color", "never", "--model", "test-model", "-" ], captured[:argv]
      assert_not_includes captured[:argv], session.prompt
      assert_equal "sk-proj-syntheticFixture", captured[:env]["CODEX_API_KEY"]
      assert_equal workspace.join("codex").to_s, captured[:env]["CODEX_HOME"]
      assert_not captured[:env].key?("ANTHROPIC_API_KEY")
      assert_not captured[:env].key?("CLAUDE_CONFIG_DIR")
      assert_equal [ "sk-proj-syntheticFixture" ], captured[:secrets]
    end
  ensure
    original.each { |name, value| ActionAgent.public_send("#{name}=", value) } if original
  end

  test "host Codex configuration and credentials cannot enter another workspace" do
    env = Backend.sanitized_environment("PATH" => "/bin", "CODEX_HOME" => "/private/config",
      "CODEX_API_KEY" => "sk-fixture", "CODEX_THREAD_ID" => "host-thread", "OPENAI_BASE_URL" => "https://elsewhere.test")
    assert_equal({ "PATH" => "/bin" }, env)
  end

  test "Codex rejects flag-like model names before starting a process" do
    session = Struct.new(:model).new("--dangerously-bypass-approvals-and-sandbox")
    assert_raises(Backend::Error) { Backend.new.send(:codex_argv, session) }
  end
end
