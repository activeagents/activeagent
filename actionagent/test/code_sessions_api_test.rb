# frozen_string_literal: true

require "test_helper"

# Claude Code sessions in a checkout sandbox (#489): started from Settings ->
# Integrations with a prompt, run in the background by CodeSessionJob through
# the sandbox backend, polled for their transcript, cancelled.
class CodeSessionsApiTest < ActionDispatch::IntegrationTest
  GITHUB_TOKEN = "gho_code_session_secret"
  CLAUDE_TOKEN = "sk-ant-oat01-codeSessionSecret_123"

  # A backend whose Claude Code session the test scripts. The orchestrator
  # builds a new backend for every call, so the script lives on the class.
  class ScriptedBackend
    class << self
      attr_accessor :script, :cancelled, :runs, :cancel_error

      def reset!
        self.script = ->(_emit) { { exit_status: 0, diff: "", stderr_tail: "" } }
        self.cancelled = []
        self.runs = []
        self.cancel_error = nil
      end
    end

    def create_sandbox(session) = { container_name: "scripted-#{session.session_id}", url: "http://127.0.0.1:9" }
    def terminate(_handle) = true
    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0

    def run_code_session(sandbox_session, code_session, &on_event)
      self.class.runs << [ sandbox_session.session_id, code_session.id, code_session.prompt ]
      self.class.script.call(on_event)
    end

    def cancel_code_session(_sandbox_session, code_session)
      self.class.cancelled << code_session.id
      raise self.class.cancel_error if self.class.cancel_error

      true
    end
  end

  # Boots sandboxes but cannot run Claude Code in them.
  class SandboxOnlyBackend
    def create_sandbox(session) = { container_name: "plain-#{session.session_id}", url: "http://127.0.0.1:9" }
    def terminate(_handle) = true
    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  def setup
    ActionAgent::CodeSession.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent::GithubConnection.delete_all
    ActionAgent::ProviderKey.delete_all
    ScriptedBackend.reset!

    @original_backends = ActionAgent.sandbox_backends
    @original_service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = {
      "scripted" => ScriptedBackend.name,
      "sandbox_only" => SandboxOnlyBackend.name
    }

    ActionAgent::GithubConnection.create!(
      access_token: GITHUB_TOKEN, github_user_id: 42, login: "octocat",
      repositories: [ { "id" => 2, "full_name" => "acme/docs", "private" => false, "default_branch" => "trunk" } ]
    )
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: CLAUDE_TOKEN)
    @sandbox = ready_checkout
  end

  def teardown
    ActionAgent.sandbox_backends = @original_backends
    ActionAgent.sandbox_service = @original_service
    ActionAgent.execution_enabled = true
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.account_class = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.multi_tenant = false
  end

  test "a session runs in a ready checkout, and its transcript is polled from an offset" do
    recorded = []
    ActionAgent.usage_recorder = ->(_owner, kind) { recorded << kind }

    post sessions_path, params: { prompt: "Add a README" }, as: :json

    assert_response :created, response.body
    created = JSON.parse(response.body)["code_session"]
    assert_equal "queued", created["status"]
    assert_equal "Add a README", created["prompt"]
    assert_equal @sandbox.session_id, created["sandbox_session_id"]
    assert_equal [ :execution ], recorded, "a session counts as an execution"
    assert_enqueued_with(job: ActionAgent::CodeSessionJob, args: [ created["id"] ])

    get sessions_path
    assert_equal [ created["id"] ], JSON.parse(response.body)["code_sessions"].map { |cs| cs["id"] }

    perform_enqueued_jobs

    get "#{sessions_path}/#{created['id']}"
    assert_response :success
    shown = JSON.parse(response.body)["code_session"]
    assert_equal "succeeded", shown["status"]
    assert_equal %w[system assistant result], shown["events"].map { |event| event["type"] }
    assert_equal 0, shown["events_offset"]
    assert_equal 1, shown["num_turns"]
    assert_match(/runs nothing/, shown["result"])
    assert_equal "", shown["diff"], "the diff is served once the session finished"
    assert shown["started_at"]
    assert shown["finished_at"]

    get "#{sessions_path}/#{created['id']}", params: { after: 2 }
    polled = JSON.parse(response.body)["code_session"]
    assert_equal [ "result" ], polled["events"].map { |event| event["type"] }
    assert_equal 2, polled["events_offset"]
  end

  test "a queued session can be cancelled, and then never runs" do
    use_scripted_backend
    post sessions_path, params: { prompt: "Refactor the models" }, as: :json
    id = JSON.parse(response.body).dig("code_session", "id")

    post "#{sessions_path}/#{id}/cancel"

    assert_response :success
    cancelled = JSON.parse(response.body)["code_session"]
    assert_equal "cancelled", cancelled["status"]
    assert cancelled["finished_at"]

    perform_enqueued_jobs

    assert_empty ScriptedBackend.runs
    assert_empty ScriptedBackend.cancelled, "a session that never started has nothing to stop"
    assert ActionAgent::CodeSession.find(id).cancelled?
  end

  test "cancelling a finished session changes nothing" do
    post sessions_path, params: { prompt: "Add a README" }, as: :json
    id = JSON.parse(response.body).dig("code_session", "id")
    perform_enqueued_jobs

    post "#{sessions_path}/#{id}/cancel"

    assert_response :success
    assert_equal "succeeded", JSON.parse(response.body).dig("code_session", "status")
  end

  test "a session is refused outside a checkout sandbox" do
    browser = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp")
    browser.mark_ready!(cloud_run_url: "http://127.0.0.1:9")

    assert_refused(browser, :unprocessable_entity, /checkout \(app_runtime\) sandbox/)
  end

  test "a session is refused until the checkout is ready" do
    @sandbox.update!(status: :provisioning)
    assert_refused(@sandbox, :unprocessable_entity, /The sandbox is provisioning; wait until it is ready/)

    @sandbox.update!(status: :ready, expires_at: 1.minute.ago)
    assert_refused(@sandbox, :unprocessable_entity, /The sandbox has expired/)
  end

  test "a session is refused when the backend cannot run Claude Code" do
    ActionAgent.sandbox_service = :sandbox_only

    assert_refused(@sandbox, :unprocessable_entity, /sandbox_only sandbox backend cannot run Claude Code sessions/)
  end

  test "a session is refused until Claude Code is connected" do
    ActionAgent::ProviderKey.delete_all

    assert_refused(@sandbox, :unprocessable_entity, /Connect Claude Code in Settings -> Integrations/)
  end

  test "only one session runs in a checkout at a time" do
    running = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: "First", status: :running)

    assert_refused(@sandbox, :conflict, /already running/)
    assert_equal running.id, JSON.parse(response.body).dig("code_session", "id")

    running.update!(status: :failed)
    post sessions_path, params: { prompt: "Second" }, as: :json
    assert_response :created
  end

  test "a session is refused when execution is disabled" do
    ActionAgent.execution_enabled = false

    assert_refused(@sandbox, :forbidden, /execution is disabled/)
  end

  test "a session is refused over the host's quota, and not counted" do
    recorded = []
    ActionAgent.quota_checker = ->(_owner, kind) { "No executions left" if kind == :execution }
    ActionAgent.usage_recorder = ->(_owner, kind) { recorded << kind }

    assert_refused(@sandbox, :payment_required, /Plan limit reached/)
    assert_empty recorded
  end

  test "a session needs a prompt, and a model that is a model name" do
    assert_refused(@sandbox, :unprocessable_entity, /Prompt can't be blank/, params: { prompt: " " })
    assert_refused(@sandbox, :unprocessable_entity, /model is not a Claude Code model name/,
      params: { prompt: "Go", model: "--dangerously-skip-permissions" })

    post sessions_path, params: { prompt: "Go", model: "claude-sonnet-4-5" }, as: :json
    assert_response :created
    assert_equal "claude-sonnet-4-5", ActionAgent::CodeSession.sole.model
  end

  test "another owner's sandbox and its sessions are not found" do
    ActionAgent.user_class = "User"
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    @sandbox.update_columns(user_id: owner.id)
    theirs = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: "Theirs", user_id: owner.id)
    ActionAgent.current_user_resolver = ->(_controller) { stranger }

    assert_refused(@sandbox, :not_found, /not found/)
    get sessions_path
    assert_response :not_found
    get "#{sessions_path}/#{theirs.id}"
    assert_response :not_found
    post "#{sessions_path}/#{theirs.id}/cancel"
    assert_response :not_found
    assert theirs.reload.queued?

    ActionAgent.current_user_resolver = ->(_controller) { owner }
    get sessions_path
    assert_equal [ theirs.id ], JSON.parse(response.body)["code_sessions"].map { |cs| cs["id"] }
  end

  test "a session is created owned like its sandbox" do
    ActionAgent.user_class = "User"
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    @sandbox.update_columns(user_id: owner.id)
    ActionAgent::ProviderKey.sole.update_columns(user_id: owner.id)
    ActionAgent::GithubConnection.sole.update_columns(user_id: owner.id)
    ActionAgent.current_user_resolver = ->(_controller) { owner }

    post sessions_path, params: { prompt: "Go" }, as: :json

    assert_response :created, response.body
    assert_equal owner.id, ActionAgent::CodeSession.sole.user_id
  end

  test "a session that reports success succeeds, with its transcript and diff stored scrubbed" do
    use_scripted_backend
    diff = "diff --git a/README.md b/README.md\n+++ b/README.md\n+token: #{GITHUB_TOKEN}\n"
    ScriptedBackend.script = lambda do |emit|
      emit.call("type" => "system", "subtype" => "init", "model" => "claude-sonnet-4-5", "session_id" => "cc-1")
      emit.call("type" => "assistant", "message" => { "role" => "assistant", "content" => [
        { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "echo #{CLAUDE_TOKEN}" } }
      ] })
      emit.call("type" => "result", "subtype" => "success", "is_error" => false, "result" => "Added the README",
        "session_id" => "cc-1", "num_turns" => 3, "duration_ms" => 4200, "total_cost_usd" => 0.0123,
        "usage" => { "input_tokens" => 120, "output_tokens" => 45 })
      { exit_status: 0, diff: diff, stderr_tail: "" }
    end

    session = run_session!("Add a README")

    assert session.succeeded?, session.error_message
    assert_equal [ [ @sandbox.session_id, session.id, "Add a README" ] ], ScriptedBackend.runs
    assert_equal %w[system assistant result], session.events.map { |event| event["type"] }
    assert_equal "echo [REDACTED]", session.events[1].dig("message", "content", 0, "input", "command")
    assert_equal "Added the README", session.result
    assert_equal "cc-1", session.claude_session_id
    assert_equal 3, session.num_turns
    assert_equal 4200, session.duration_ms
    assert_in_delta 0.0123, session.total_cost_usd.to_f
    assert_equal [ 120, 45 ], [ session.input_tokens, session.output_tokens ]
    assert_includes session.diff, "diff --git a/README.md b/README.md"
    assert_includes session.diff, "+token: [REDACTED]"
    assert_nil session.error_message
    assert session.started_at
    assert session.finished_at

    get "#{sessions_path}/#{session.id}"
    [ GITHUB_TOKEN, CLAUDE_TOKEN ].each { |secret| assert_not_includes response.body, secret }
  end

  test "a session whose result is an error fails with Claude Code's own message" do
    use_scripted_backend
    ScriptedBackend.script = lambda do |emit|
      emit.call("type" => "result", "subtype" => "success", "is_error" => true,
        "result" => "Invalid API key · Please run /login", "num_turns" => 1)
      { exit_status: 1, diff: "", stderr_tail: "" }
    end

    session = run_session!

    assert session.failed?
    assert_equal "Invalid API key · Please run /login", session.error_message
    assert session.finished_at
  end

  test "a session that ran out of turns fails, whatever its is_error says" do
    use_scripted_backend
    ScriptedBackend.script = lambda do |emit|
      emit.call("type" => "result", "subtype" => "error_max_turns", "is_error" => false, "num_turns" => 30)
      { exit_status: 0, diff: "", stderr_tail: "" }
    end

    session = run_session!

    assert session.failed?
    assert_equal "Claude Code stopped: error_max_turns", session.error_message
  end

  test "a session that exits without a result fails with the scrubbed stderr tail" do
    use_scripted_backend
    ScriptedBackend.script = lambda do |_emit|
      { exit_status: 2, diff: "", stderr_tail: "fatal: could not read Username (token #{GITHUB_TOKEN})\n" }
    end

    session = run_session!

    assert session.failed?
    assert_equal "Claude Code exited with status 2: fatal: could not read Username (token [REDACTED])", session.error_message
  end

  test "a session whose backend raises fails with the scrubbed message" do
    use_scripted_backend
    ScriptedBackend.script = lambda do |emit|
      emit.call("type" => "system", "subtype" => "init")
      raise "claude could not start with CLAUDE_CODE_OAUTH_TOKEN=#{CLAUDE_TOKEN}"
    end

    session = run_session!

    assert session.failed?
    assert_equal "claude could not start with CLAUDE_CODE_OAUTH_TOKEN=[REDACTED]", session.error_message
    assert session.finished_at
    assert_equal 1, session.events.size, "what arrived before the error is kept"
  end

  test "a session cancelled while it runs is stopped through the backend and stays cancelled" do
    use_scripted_backend
    sandbox_path = sessions_path
    ScriptedBackend.script = lambda do |emit|
      emit.call("type" => "system", "subtype" => "init")
      # The owner presses Cancel while Claude Code is working.
      id = ActionAgent::CodeSession.sole.id
      post "#{sandbox_path}/#{id}/cancel"
      assert_response :success
      assert_equal [ id ], ScriptedBackend.cancelled, "the cancel stops the process at once"
      cancelled = JSON.parse(response.body)["code_session"]
      assert_equal "cancelled", cancelled["status"]
      assert_equal true, cancelled["diff_pending"], "Claude Code is still stopping, so its diff is still to come"
      get "#{sandbox_path}/#{id}"
      assert_equal true, JSON.parse(response.body).dig("code_session", "diff_pending")
      emit.call("type" => "assistant", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "Stopping" } ] })
      emit.call("type" => "assistant", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "Stopped" } ] })
      { exit_status: 143, diff: "diff --git a/half b/half\n", stderr_tail: "Terminated" }
    end

    session = run_session!

    assert session.cancelled?
    assert_equal [ session.id, session.id ], ScriptedBackend.cancelled,
      "the job sends the stop again once it sees the cancel, and only once"
    assert_nil session.error_message
    assert session.finished_at
    assert_equal 3, session.events.size
    assert_includes session.diff, "diff --git a/half b/half", "what the session changed before it stopped is kept"
    get "#{sessions_path}/#{session.id}"
    shown = JSON.parse(response.body)["code_session"]
    assert_equal false, shown["diff_pending"], "settled once the job recorded the diff"
    assert_includes shown["diff"], "diff --git a/half b/half"
  end

  test "a session the backend refused after a cancel is settled with no diff to come" do
    use_scripted_backend
    sandbox_path = sessions_path
    ScriptedBackend.script = lambda do |_emit|
      # Claimed by the job; the cancel lands before the backend spawned
      # Claude Code, which then refuses to start it at all.
      id = ActionAgent::CodeSession.sole.id
      post "#{sandbox_path}/#{id}/cancel"
      assert_equal true, JSON.parse(response.body).dig("code_session", "diff_pending")
      raise ActionAgent::LocalSandboxBackend::Error, "Claude Code session #{id} was cancelled before it started"
    end

    session = run_session!

    assert session.cancelled?, "the refusal does not turn the cancel into a failure"
    assert_nil session.error_message
    assert session.finished_at
    get "#{sessions_path}/#{session.id}"
    shown = JSON.parse(response.body)["code_session"]
    assert_equal false, shown["diff_pending"], "nothing ran, so no diff is coming"
    assert_nil shown["diff"]
  end

  test "a queued session is unsettled until a cancel settles it" do
    use_scripted_backend
    post sessions_path, params: { prompt: "Fix it" }, as: :json
    id = JSON.parse(response.body).dig("code_session", "id")
    get "#{sessions_path}/#{id}"
    assert_equal true, JSON.parse(response.body).dig("code_session", "diff_pending"), "queued: everything is still to come"

    post "#{sessions_path}/#{id}/cancel"
    assert_equal false, JSON.parse(response.body).dig("code_session", "diff_pending"),
      "cancelled in the queue: nothing will ever run it"
  end

  test "a session's sandbox must belong to the caller's current account" do
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User" # the dummy app has no Account
    ActionAgent.multi_tenant = true
    me = User.create!(email: "me-#{SecureRandom.hex(3)}@example.com", name: "Me", age: 30)
    first = User.create!(email: "first-#{SecureRandom.hex(3)}@example.com", name: "First", age: 30)
    second = User.create!(email: "second-#{SecureRandom.hex(3)}@example.com", name: "Second", age: 30)
    @sandbox.update_columns(user_id: me.id, account_id: second.id)
    theirs = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: "Theirs", user_id: me.id, account_id: second.id)
    account = first
    ActionAgent.current_user_resolver = ->(_controller) { me }
    ActionAgent.current_account_resolver = ->(_controller) { account }

    # The caller owns the sandbox, but switched to another account.
    assert_refused(@sandbox, :not_found, /not found/)
    get sessions_path
    assert_response :not_found
    get "#{sessions_path}/#{theirs.id}"
    assert_response :not_found
    post "#{sessions_path}/#{theirs.id}/cancel"
    assert_response :not_found
    assert theirs.reload.queued?

    account = second
    get sessions_path
    assert_response :success
    assert_equal [ theirs.id ], JSON.parse(response.body)["code_sessions"].map { |cs| cs["id"] }
  end

  test "a transcript keeps its first 1,000 events and counts the rest" do
    session = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: "Go")
    # The first 999 as the column holds them; the last two through the cap.
    session.update_column(:events, Array.new(999) { |index| { "type" => "assistant", "n" => index } })

    session.append_event!({ "type" => "assistant", "n" => 999 })
    session.append_event!({ "type" => "result", "n" => 1000 })

    session.reload
    assert_equal ActionAgent::CodeSession::MAX_EVENTS, session.events.size
    assert_equal 999, session.events.last["n"]
    assert_equal 1, session.dropped_events_count
    assert_equal 1_001, session.summary[:event_count]
    assert_equal 1, session.details[:dropped_events_count]
  end

  test "a diff over 500 KB is truncated with a notice" do
    session = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: "Go")

    session.update!(diff: "+#{"x" * 600_000}\n")

    stored = session.reload.diff
    assert_operator stored.bytesize, :<, 600_000
    assert stored.start_with?("+#{"x" * 1000}")
    assert stored.end_with?("\n… diff truncated")
    assert_equal ActionAgent::CodeSession::MAX_DIFF_BYTES + "\n… diff truncated".bytesize, stored.bytesize

    session.update!(diff: "+small\n")
    assert_equal "+small\n", session.reload.diff, "a diff under the limit is kept whole"
  end

  test "a session cancelled before Claude Code started is stopped once it has" do
    use_scripted_backend
    sandbox_path = sessions_path
    ScriptedBackend.script = lambda do |emit|
      # Claimed by the job, but the backend has not spawned Claude Code yet:
      # the cancel's stop finds no process, and does nothing.
      id = ActionAgent::CodeSession.sole.id
      post "#{sandbox_path}/#{id}/cancel"
      assert_equal "cancelled", JSON.parse(response.body).dig("code_session", "status")
      assert_equal [ id ], ScriptedBackend.cancelled

      # Spawned: its first event is the first moment there is a process to stop.
      emit.call("type" => "system", "subtype" => "init")
      assert_equal [ id, id ], ScriptedBackend.cancelled, "stopped as soon as it started, not when it finished"
      emit.call("type" => "result", "subtype" => "success", "is_error" => false, "result" => "Edited anyway", "num_turns" => 1)
      { exit_status: 143, diff: "", stderr_tail: "Terminated" }
    end

    session = run_session!

    assert session.cancelled?, "the outcome does not overwrite the cancel"
    assert_equal [ session.id, session.id ], ScriptedBackend.cancelled
    assert_nil session.error_message
  end

  test "a failing stop does not fail the cancelled session" do
    use_scripted_backend
    sandbox_path = sessions_path
    ScriptedBackend.script = lambda do |emit|
      post "#{sandbox_path}/#{ActionAgent::CodeSession.sole.id}/cancel"
      ScriptedBackend.cancel_error = RuntimeError.new("state.json is locked")
      emit.call("type" => "system", "subtype" => "init")
      emit.call("type" => "result", "subtype" => "success", "is_error" => false, "num_turns" => 1)
      { exit_status: 0, diff: "", stderr_tail: "" }
    end

    session = run_session!

    assert session.cancelled?
    assert_nil session.error_message
    assert_equal 2, session.events.size
  end

  test "a session queued behind a Stop never starts Claude Code" do
    use_scripted_backend
    post sessions_path, params: { prompt: "Fix the failing test" }, as: :json
    assert_response :created
    id = JSON.parse(response.body).dig("code_session", "id")

    # The Stop lands before the session's job runs.
    delete "/activeagents/api/sandboxes/#{@sandbox.session_id}"
    perform_enqueued_jobs(only: ActionAgent::CodeSessionJob)

    session = ActionAgent::CodeSession.find(id)
    assert session.failed?
    assert_match(/stopped before the session started/, session.error_message)
    assert_empty ScriptedBackend.runs, "the backend was never asked to run it"
    assert_not session.diff_pending?, "settled: nothing will run it"
  end

  private

  def sessions_path(sandbox = @sandbox)
    "/activeagents/api/sandboxes/#{sandbox.session_id}/code_sessions"
  end

  def use_scripted_backend
    ActionAgent.sandbox_service = :scripted
  end

  # A checkout provisioned through the configured (mock) backend.
  def ready_checkout
    sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")
    sandbox.provision!
    perform_enqueued_jobs
    sandbox.reload
    assert sandbox.ready?
    sandbox
  end

  # Starts a session through the API and runs its job.
  def run_session!(prompt = "Fix the failing test")
    post sessions_path, params: { prompt: prompt }, as: :json
    assert_response :created, response.body
    id = JSON.parse(response.body).dig("code_session", "id")
    perform_enqueued_jobs
    ActionAgent::CodeSession.find(id)
  end

  # Asserts that starting a session in +sandbox+ is answered with +status+
  # and an error matching +message+, and that nothing was started.
  def assert_refused(sandbox, status, message, params: { prompt: "Add a README" })
    assert_no_difference -> { ActionAgent::CodeSession.count } do
      assert_no_enqueued_jobs(only: ActionAgent::CodeSessionJob) do
        post sessions_path(sandbox), params: params, as: :json
      end
    end
    assert_response status
    assert_match message, JSON.parse(response.body)["error"].to_s
  end
end
