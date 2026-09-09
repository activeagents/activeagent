# frozen_string_literal: true

require "test_helper"

# A backend that only knows one of the catalog's coding agents — what a host
# app registers when its image carries Claude Code and nothing else.
class ClaudeOnlyCodeBackend < ActionAgent::MockCodeSessionBackend
  def supported_tools
    [ "claude_code" ]
  end
end

# <mount>/api/code_sessions — handing an agent, its evaluation findings and a
# repository to a coding agent in a sandbox, through the engine mounted in
# the dummy app at /activeagents.
#
# Everything runs on the in-memory backend, which records what it was handed
# and runs nothing, so these cover the parts that are ours: the catalog the
# form is built from, the brief the session persists, the jobs that
# provision and run it, the refusals, and the GitHub token's path from the
# owner's credentials to the backend without ever passing through a column.
class CodeSessionsApiTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::CodeSession.delete_all
    ActionAgent::ProviderKey.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent.code_session_backend = "mock"
    ActionAgent::MockCodeSessionBackend.reset!
  end

  def teardown
    ActionAgent.code_session_backend = :mock
    ActionAgent.code_session_backends = {}
    ActionAgent.code_session_limits = nil
    ActionAgent.execution_enabled = true
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
    ActionAgent.github_token_resolver = nil
  end

  def create_agent(**attributes)
    ActionAgent::Agent.create!({
      name: "Scheduler", provider: "mock", model: "mock-model",
      instructions: "Answer scheduling questions from the practice data.", tools: [ "find_records" ]
    }.merge(attributes))
  end

  def post_session(agent, **attributes)
    post "/activeagents/api/code_sessions",
      params: { code_session: { agent_id: agent.id, tool: "claude_code" }.merge(attributes) }, as: :json
  end

  def body
    JSON.parse(response.body)
  end

  # ENV["GITHUB_TOKEN"] is the last fallback github_token_for reaches on a
  # single-tenant install, so a test about a missing token has to own it.
  def without_env(*names)
    saved = names.to_h { |name| [ name, ENV[name] ] }
    names.each { |name| ENV.delete(name) }
    yield
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  # --- catalog ------------------------------------------------------------

  test "the catalog is everything the New Code Session form is built from" do
    ActionAgent.github_token_resolver = ->(_owner, _session) { "ghp_from_the_host_app" }

    get "/activeagents/api/code_sessions/catalog"

    assert_response :success
    claude = body["tools"].find { |tool| tool["key"] == "claude_code" }
    assert_equal "Claude Code", claude["name"]
    assert claude["supported"], "the mock backend launches every catalog entry"
    assert_not claude["experimental"]
    assert_equal [ %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN] ], claude["credentials"]
    assert claude["needs"].any?
    assert claude["limitations"].any?
    assert body["tools"].find { |tool| tool["key"] == "codex" }["experimental"]

    assert_includes body["backends"], "mock"
    assert_includes body["backends"], "code_on_incus"
    assert_equal "mock", body["default_backend"]
    assert_equal ActionAgent::CodeSession::NETWORK_MODES, body["network_modes"]
    assert_equal ActionAgent::CodeSession::GITHUB_ACCESS, body["github_access_modes"]
    assert body["github_configured"], "the host app's resolver answers with a token"
    assert_equal 5, body.dig("limits", "max_sessions_per_owner")
    assert_equal 240, body.dig("limits", "session_duration_minutes")
    assert_equal 3600, body.dig("limits", "run_timeout_seconds")
  end

  test "a backend that knows only some of the catalog says which, and why not" do
    ActionAgent.code_session_backends = { "claude_only" => "ClaudeOnlyCodeBackend" }
    ActionAgent.code_session_backend = "claude_only"

    get "/activeagents/api/code_sessions/catalog"

    assert_response :success
    assert body["tools"].find { |tool| tool["key"] == "claude_code" }["supported"]
    codex = body["tools"].find { |tool| tool["key"] == "codex" }
    assert_not codex["supported"]
    assert_match(/cannot launch Codex CLI/, codex["reason"])
  end

  test "no GitHub token anywhere is reported as unconfigured rather than assumed" do
    without_env("GITHUB_TOKEN") do
      get "/activeagents/api/code_sessions/catalog"
    end

    assert_response :success
    assert_not body["github_configured"]
  end

  # --- the brief ----------------------------------------------------------

  test "the brief can be previewed without creating anything" do
    agent = create_agent

    post "/activeagents/api/code_sessions/preview_brief",
      params: { code_session: { agent_id: agent.id, tool: "claude_code", github_access: "write" } }, as: :json

    assert_response :success
    assert_equal "Scheduler", body.dig("brief", "agent", "name")
    assert_equal "claude_code", body.dig("brief", "code_agent", "tool")
    assert_includes body["markdown"], "# Brief for Claude Code"
    assert_includes body["markdown"], "## Your sandbox"
    assert_equal 0, ActionAgent::CodeSession.count, "a preview creates nothing"
    assert_no_enqueued_jobs
  end

  # --- create -------------------------------------------------------------

  test "creating a session persists its brief, defaults the task from it and queues provisioning" do
    agent = create_agent

    assert_enqueued_with(job: ActionAgent::CodeSessionProvisionJob) do
      post_session(agent, repository: "https://github.com/acme/app", network_mode: "allowlist")
    end

    assert_response :created
    session = ActionAgent::CodeSession.find(body.dig("session", "id"))
    assert_equal "pending", session.status
    assert_equal "acme/app", session.repository, "a pasted browser URL is normalized to owner/repo"
    assert_equal "mock", session.backend
    assert_equal agent.id, session.agent_id

    assert_equal 1, session.brief["version"]
    assert_equal "Scheduler", session.brief.dig("agent", "name")
    assert_equal "allowlist", session.brief.dig("sandbox", "network_mode")
    assert_equal session.brief["task"], session.task
    assert_match(%r{Work in /workspace/repo}, session.task)

    assert_enqueued_with(job: ActionAgent::CodeSessionProvisionJob, args: [ session.id, false ])
  end

  test "a task the operator wrote is used instead of the brief's" do
    agent = create_agent

    post_session(agent, task: "Add a send_provider_reminder tool and cover it with a test.")

    assert_response :created
    assert_equal "Add a send_provider_reminder tool and cover it with a test.",
      ActionAgent::CodeSession.first.task
  end

  test "create with run provisions and then runs the coding agent through the backend" do
    agent = create_agent

    perform_enqueued_jobs do
      post_session(agent, run: true, repository: "acme/app")
    end

    assert_response :created
    session = ActionAgent::CodeSession.first
    assert_equal "completed", session.status
    assert_equal 0, session.exit_code
    assert_includes session.transcript, "[mock] Claude Code in acme/app"
    assert session.container_id.present?, "the backend reported a container"

    labels = session.events.map { |event| event["label"] }
    assert_includes labels, "Provisioning Claude Code sandbox"
    assert_includes labels, "Sandbox ready"
    assert_includes labels, "Claude Code running"
    assert_includes labels, "Run finished"
    assert_equal %w[session session run run], session.events.map { |event| event["kind"] }

    launch = ActionAgent::MockCodeSessionBackend.launches.last
    assert_equal "acme/app", launch[:repository]
    assert_equal "claude_code", launch[:tool]
    assert_equal 1, ActionAgent::MockCodeSessionBackend.runs.size
  end

  # --- the GitHub token ---------------------------------------------------

  test "the GitHub token reaches the backend and never the database" do
    agent = create_agent
    token = "ghp_only_the_sandbox_sees_this"
    ActionAgent::ProviderKey.create!(provider: "github", credential: token)

    perform_enqueued_jobs do
      post_session(agent, github_access: "read", repository: "acme/app")
    end

    assert_response :created
    assert_equal token, ActionAgent::MockCodeSessionBackend.launches.last[:github_token]

    session = ActionAgent::CodeSession.first
    assert_not_includes session.attributes.to_json, token, "no column may carry the token"
    assert_not_includes response.body, token
  end

  test "a session with no GitHub access is launched without a token even when one is stored" do
    agent = create_agent
    ActionAgent::ProviderKey.create!(provider: "github", credential: "ghp_only_the_sandbox_sees_this")

    perform_enqueued_jobs do
      post_session(agent, github_access: "none")
    end

    assert_response :created
    assert_nil ActionAgent::MockCodeSessionBackend.launches.last[:github_token]
  end

  # --- refusals -----------------------------------------------------------

  test "an observed agent has no code of ours to improve" do
    agent = create_agent(status: :observed)

    post_session(agent)

    assert_response :unprocessable_entity
    assert_match(/read-only/, body["error"])
    assert_equal 0, ActionAgent::CodeSession.count
  end

  test "a tool the backend cannot launch is refused rather than queued" do
    ActionAgent.code_session_backends = { "claude_only" => "ClaudeOnlyCodeBackend" }
    agent = create_agent

    post_session(agent, tool: "codex", backend: "claude_only")

    assert_response :unprocessable_entity
    assert_match(/Codex CLI cannot be launched by the claude_only backend/, body["error"])
    assert_equal 0, ActionAgent::CodeSession.count
    assert_no_enqueued_jobs
  end

  test "a repository that is not owner/repo is refused" do
    agent = create_agent

    post_session(agent, repository: "../../etc/passwd")

    assert_response :unprocessable_entity
    assert_includes body["errors"].join(" "), "must look like owner/repo"
    assert_equal 0, ActionAgent::CodeSession.count
  end

  test "starting a session is agent execution: refused when the dashboard's execution is off" do
    agent = create_agent
    ActionAgent.execution_enabled = false

    post_session(agent)

    assert_response :forbidden
    assert_equal 0, ActionAgent::CodeSession.count
  end

  test "the host app's execution quota gates starting a session" do
    agent = create_agent
    ActionAgent.quota_checker = ->(_owner, kind) { "Out of runs" if kind == :execution }

    post_session(agent)

    assert_response :payment_required
    assert_equal "Out of runs", body["message"]
    assert_equal 0, ActionAgent::CodeSession.count
  end

  test "an owner can only hold so many sandboxes at once" do
    agent = create_agent
    ActionAgent.code_session_limits = { max_sessions_per_owner: 1 }
    ActionAgent::CodeSession.create!(agent: agent, tool: "claude_code", backend: "mock", status: :ready)

    post_session(agent)

    assert_response :unprocessable_entity
    assert_match(/You already have 1 active code sessions/, body["error"])
    assert_equal 1, ActionAgent::CodeSession.count
  end

  # --- reading a session --------------------------------------------------

  test "show carries the brief, the timeline and how to attach; events is the poll target" do
    agent = create_agent
    perform_enqueued_jobs { post_session(agent, run: true) }
    session = ActionAgent::CodeSession.first

    get "/activeagents/api/code_sessions/#{session.id}"

    assert_response :success
    detail = body["session"]
    assert_equal "Scheduler", detail.dig("brief", "agent", "name")
    assert detail["events"].any?
    assert_includes detail["transcript"], "[mock]"
    assert detail.key?("attach_command"), "the mock backend offers no attach command, and says so"

    get "/activeagents/api/code_sessions/#{session.id}/events"

    assert_response :success
    assert_equal "completed", body["status"]
    assert_equal session.events.size, body["events"].size
    assert_includes body["transcript"], "[mock]"
    assert_equal 0, body["exit_code"]

    get "/activeagents/api/code_sessions/#{session.id}/brief"

    assert_response :success
    assert_includes body["markdown"], "## Your sandbox"
  end

  # --- running, stopping, deleting ----------------------------------------

  test "a ready session runs again on demand and records what the coding agent produced" do
    agent = create_agent
    session = ActionAgent::CodeSession.create!(agent: agent, tool: "claude_code", backend: "mock",
      status: :ready, task: "Add the missing tool.")

    perform_enqueued_jobs do
      post "/activeagents/api/code_sessions/#{session.id}/run", params: { prompt: "Just run the tests." }, as: :json
    end

    assert_response :accepted
    session.reload
    assert_equal "completed", session.status
    assert_includes session.transcript, "Just run the tests."
    assert_equal "Just run the tests.", ActionAgent::MockCodeSessionBackend.runs.last[:prompt]
  end

  test "a session whose sandbox does not exist yet cannot be run" do
    agent = create_agent
    session = ActionAgent::CodeSession.create!(agent: agent, tool: "claude_code", backend: "mock", status: :pending)

    post "/activeagents/api/code_sessions/#{session.id}/run"

    assert_response :unprocessable_entity
    assert_equal "This session is not ready to run", body["error"]
    assert_equal "pending", session.reload.status
    assert_no_enqueued_jobs only: ActionAgent::CodeSessionRunJob
  end

  test "stopping a session marks it stopped and queues the sandbox's release" do
    agent = create_agent
    session = ActionAgent::CodeSession.create!(agent: agent, tool: "claude_code", backend: "mock", status: :ready)

    assert_enqueued_with(job: ActionAgent::CodeSessionCleanupJob, args: [ session.id ]) do
      post "/activeagents/api/code_sessions/#{session.id}/stop"
    end

    assert_response :success
    assert_equal "stopped", session.reload.status
    assert session.completed_at.present?
    assert_equal [ "Stopped by the dashboard" ], session.events.map { |event| event["label"] }
  end

  test "deleting a session terminates its sandbox inline, before the row is gone" do
    agent = create_agent
    session = ActionAgent::CodeSession.create!(agent: agent, tool: "claude_code", backend: "mock", status: :ready)

    delete "/activeagents/api/code_sessions/#{session.id}"

    assert_response :no_content
    assert_equal [ session.session_id ], ActionAgent::MockCodeSessionBackend.terminations
    assert_equal 0, ActionAgent::CodeSession.count
  end

  # --- metering -----------------------------------------------------------

  test "one run is one execution: metered at create when it runs, and once per run afterwards" do
    agent = create_agent
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind) { recorded << [ owner, kind ] }

    perform_enqueued_jobs { post_session(agent, run: true) }

    assert_response :created
    assert_equal [ [ nil, :execution ] ], recorded

    session = ActionAgent::CodeSession.first
    perform_enqueued_jobs { post "/activeagents/api/code_sessions/#{session.id}/run" }

    assert_response :accepted
    assert_equal [ [ nil, :execution ] ] * 2, recorded, "the job must not meter the run a second time"
  end

  test "a session that only provisions is not metered as an execution" do
    agent = create_agent
    recorded = []
    ActionAgent.usage_recorder = ->(_owner, kind) { recorded << kind }

    perform_enqueued_jobs { post_session(agent) }

    assert_response :created
    assert_empty recorded
  end
end

# In a per-user install a sandbox belongs to whoever opened it: it carries
# their agent, their brief and, while it lives, their GitHub token.
class CodeSessionOwnershipTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::CodeSession.delete_all
    ActionAgent::Agent.delete_all
    User.delete_all

    @user = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    @other = User.create!(email: "other-#{SecureRandom.hex(3)}@example.com", name: "Other", age: 30)
    ActionAgent.user_class = "User"
    ActionAgent.current_user_resolver = ->(_controller) { @user }
    ActionAgent.code_session_backend = "mock"
    ActionAgent::MockCodeSessionBackend.reset!
  end

  def teardown
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.code_session_backend = :mock
  end

  # The owner columns are written directly: the belongs_to is declared from
  # configuration when the model loads, and this install configured its user
  # class afterwards — the same thing SessionRecordingOwnershipTest does.
  def create_session_for(user)
    agent = ActionAgent::Agent.new(name: "Scheduler #{user.id}", provider: "mock", model: "mock-model")
    agent.user_id = user.id
    agent.save!

    session = ActionAgent::CodeSession.new(agent: agent, tool: "claude_code", backend: "mock",
      status: :ready, task: "Fix the sync tool.")
    session.user_id = user.id
    session.save!
    session
  end

  test "another user's code session is not readable, runnable or listed" do
    session = create_session_for(@user)

    get "/activeagents/api/code_sessions/#{session.id}"
    assert_response :success

    ActionAgent.current_user_resolver = ->(_controller) { @other }

    get "/activeagents/api/code_sessions/#{session.id}"
    assert_response :not_found

    post "/activeagents/api/code_sessions/#{session.id}/run"
    assert_response :not_found

    get "/activeagents/api/code_sessions"
    assert_response :success
    assert_empty JSON.parse(response.body)["sessions"]
  end
end
