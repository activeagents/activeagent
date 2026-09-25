# frozen_string_literal: true

require "test_helper"

# A checkout sandbox's lifecycle (#489): provisioned in the background, alive
# for two hours, its failures reported without its secrets, and released
# through the backend that booted it — in development too, where a :local
# checkout is a set of child processes of the dashboard itself.
class SandboxLifecycleTest < ActionDispatch::IntegrationTest
  GITHUB_TOKEN = "gho_lifecycle_secret_token"
  CLAUDE_TOKEN = "sk-ant-oat01-lifecycleSecret_123"

  # Records what the engine asks of a backend. The orchestrator builds a new
  # backend for every call, so what it saw lives on the class.
  class ProbeBackend
    class << self
      attr_accessor :calls, :create_error, :terminate_result, :while_booting

      def reset!
        self.calls = []
        self.create_error = nil
        self.terminate_result = true
        self.while_booting = nil
      end
    end

    def create_sandbox(session)
      self.class.calls << [ :create, session.session_id ]
      self.class.while_booting&.call
      raise self.class.create_error if self.class.create_error

      {
        container_name: "probe-#{session.session_id}",
        url: "http://127.0.0.1:9",
        container_ip: "127.0.0.1",
        mcp_url: "http://127.0.0.1:9/activeagents/mcp",
        mcp_token: "probe-mcp-token"
      }
    end

    def terminate(handle)
      self.class.calls << [ :terminate, handle ]
      result = self.class.terminate_result
      raise result if result.is_a?(Exception)

      result
    end

    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  # Makes SandboxSession#mark_ready! raise while +error+ is set, as a locked
  # database or a misconfigured encryption key would. Inert otherwise.
  module FailingMarkReady
    class << self
      attr_accessor :error
    end

    def mark_ready!(...)
      raise FailingMarkReady.error if FailingMarkReady.error

      super
    end
  end
  ActionAgent::SandboxSession.prepend(FailingMarkReady)

  def setup
    ActionAgent::CodeSession.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent::GithubConnection.delete_all
    ActionAgent::ProviderKey.delete_all
    ProbeBackend.reset!

    @original_backends = ActionAgent.sandbox_backends
    @original_service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = { "probe" => ProbeBackend.name }
    ActionAgent.sandbox_service = :probe

    @connection = ActionAgent::GithubConnection.create!(
      access_token: GITHUB_TOKEN, github_user_id: 42, login: "octocat",
      repositories: [ { "id" => 2, "full_name" => "acme/docs", "private" => false, "default_branch" => "trunk" } ]
    )
  end

  def teardown
    FailingMarkReady.error = nil
    ActionAgent.sandbox_backends = @original_backends
    ActionAgent.sandbox_service = @original_service
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
  end

  test "a checkout is provisioned in the background and polled until ready" do
    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/docs" }, as: :json

    assert_response :created, response.body
    sandbox = JSON.parse(response.body)["sandbox"]
    assert_equal "provisioning", sandbox["status"], "the request does not wait for the checkout to boot"
    assert_nil sandbox["runtime_server_key"]
    assert_nil sandbox["error_message"]
    assert_empty ProbeBackend.calls
    assert_enqueued_jobs 1, only: ActionAgent::SandboxProvisionJob

    perform_enqueued_jobs

    get "/activeagents/api/sandboxes/#{sandbox['session_id']}"
    polled = JSON.parse(response.body)["sandbox"]
    assert_equal "ready", polled["status"]
    assert_equal "sandbox:#{sandbox['session_id']}", polled["runtime_server_key"]
    assert_equal [ [ :create, sandbox["session_id"] ] ], ProbeBackend.calls
    assert_equal "probe-#{sandbox['session_id']}", session_for(sandbox).cloud_run_job_id
    assert_not_includes response.body, "probe-mcp-token"
  end

  test "other sandbox types are still simulated at once in development and test" do
    post "/activeagents/api/sandboxes", params: { sandbox_type: "playwright_mcp" }, as: :json

    assert_response :created
    assert_equal "ready", JSON.parse(response.body).dig("sandbox", "status")
    assert_no_enqueued_jobs only: ActionAgent::SandboxProvisionJob
  end

  test "a checkout lives for two hours and the other types for fifteen minutes" do
    freeze_time do
      checkout = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")
      browser = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp")

      assert_equal 2.hours.from_now, checkout.expires_at
      assert_equal 15.minutes.from_now, browser.expires_at
    end
  end

  test "a provisioning failure is reported in the summary without the session's secrets" do
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: CLAUDE_TOKEN)
    ProbeBackend.create_error = RuntimeError.new(
      "setup failed: git fetch https://x-access-token:#{GITHUB_TOKEN}@github.com/acme/docs.git " \
      "with CLAUDE_CODE_OAUTH_TOKEN=#{CLAUDE_TOKEN}"
    )

    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/docs" }, as: :json
    session_id = JSON.parse(response.body).dig("sandbox", "session_id")
    perform_enqueued_jobs

    get "/activeagents/api/sandboxes/#{session_id}"
    sandbox = JSON.parse(response.body)["sandbox"]
    assert_equal "failed", sandbox["status"]
    assert_match(/\Asetup failed: git fetch/, sandbox["error_message"])
    assert_includes sandbox["error_message"], "[REDACTED]"
    [ GITHUB_TOKEN, CLAUDE_TOKEN ].each do |secret|
      assert_not_includes response.body, secret
      assert_not_includes ActionAgent::SandboxSession.find_by!(session_id: session_id).error_message, secret
    end
  end

  test "the summary's error message is bounded but keeps the log tail" do
    session = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp")
    # A failed boot's shape: the reason first, the failing step's log after,
    # with the actual error on its last line.
    message = "setup failed: bundle install exited 1\n#{"log line\n" * 1_000}Could not find gem 'nope'"
    session.update_column(:error_message, message)

    shown = session.summary[:error_message]
    assert_operator shown.length, :<, 2_100
    assert shown.start_with?("setup failed: bundle install exited 1")
    assert shown.end_with?("Could not find gem 'nope'")

    session.update_column(:error_message, "short")
    assert_equal "short", session.summary[:error_message]
  end

  test "a repository dropped from the selection fails provisioning with a clear message" do
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")
    @connection.update!(repositories: [])

    session.provision!
    perform_enqueued_jobs

    session.reload
    assert session.failed?
    assert_equal "acme/docs is no longer available: reconnect GitHub or reselect it in Settings -> Integrations",
      session.error_message
    assert_empty ProbeBackend.calls, "nothing is handed to the backend"
  end

  test "the provision job ignores a session that no longer exists" do
    assert_nothing_raised { ActionAgent::SandboxProvisionJob.perform_now(0) }

    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")
    session.provision!
    session.destroy!

    assert_nothing_raised { perform_enqueued_jobs }
    assert_empty ProbeBackend.calls
  end

  test "the provision job does not provision a session a second time" do
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")
    session.mark_ready!(cloud_run_url: "http://127.0.0.1:9", cloud_run_job_id: "probe-first")

    ActionAgent::SandboxProvisionJob.perform_now(session.id)
    session.update!(status: :failed)
    ActionAgent::SandboxProvisionJob.perform_now(session.id)

    assert_empty ProbeBackend.calls
    assert_equal "probe-first", session.reload.cloud_run_job_id
  end

  test "a checkout stopped before it boots is never handed to the backend" do
    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/docs" }, as: :json
    session_id = JSON.parse(response.body).dig("sandbox", "session_id")

    delete "/activeagents/api/sandboxes/#{session_id}"
    assert_response :success
    perform_enqueued_jobs

    assert ActionAgent::SandboxSession.find_by!(session_id: session_id).expired?
    assert_empty ProbeBackend.calls
  end

  test "a checkout stopped while it boots is released rather than revived" do
    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/docs" }, as: :json
    session_id = JSON.parse(response.body).dig("sandbox", "session_id")
    ProbeBackend.while_booting = -> { delete "/activeagents/api/sandboxes/#{session_id}" }

    perform_enqueued_jobs

    session = ActionAgent::SandboxSession.find_by!(session_id: session_id)
    assert session.expired?, "the stop wins over the boot that finished after it"
    assert_nil session.runtime_mcp_url
    assert_nil session.cloud_run_job_id
    assert_equal [ [ :create, session_id ], [ :terminate, "probe-#{session_id}" ] ], ProbeBackend.calls
  end

  test "a checkout stopped while its boot fails stays stopped" do
    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/docs" }, as: :json
    session_id = JSON.parse(response.body).dig("sandbox", "session_id")
    ProbeBackend.while_booting = -> { delete "/activeagents/api/sandboxes/#{session_id}" }
    ProbeBackend.create_error = RuntimeError.new("setup failed")

    perform_enqueued_jobs

    session = ActionAgent::SandboxSession.find_by!(session_id: session_id)
    assert session.expired?
    assert_nil session.error_message
  end

  test "a stop that loaded the checkout before its boot finished still terminates it" do
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")
    session.provision!
    # What DELETE (or the reaper) loaded while the backend was still booting.
    stale = ActionAgent::SandboxSession.find(session.id)
    perform_enqueued_jobs
    assert session.reload.ready?

    assert_enqueued_with(job: ActionAgent::SandboxCleanupJob, args: [ session.id ]) { stale.expire! }

    session.reload
    assert session.expired?
    assert_nil session.runtime_mcp_url, "the endpoint recorded after the copy was loaded is cleared"
    assert_nil session.runtime_mcp_token
    perform_enqueued_jobs
    assert_equal [ [ :create, session.session_id ], [ :terminate, "probe-#{session.session_id}" ] ], ProbeBackend.calls
    assert_nil session.reload.cloud_run_job_id
  end

  test "a checkout that booted but could not be marked ready is released, and fails" do
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")
    session.provision!
    FailingMarkReady.error = ActiveRecord::StatementInvalid.new("SQLite3::BusyException: database is locked")

    perform_enqueued_jobs

    session.reload
    assert session.failed?
    assert_equal "SQLite3::BusyException: database is locked", session.error_message
    assert_nil session.cloud_run_job_id
    assert_equal [ [ :create, session.session_id ], [ :terminate, "probe-#{session.session_id}" ] ], ProbeBackend.calls,
      "nothing recorded the handle, so the job releases what it booted"
  end

  test "a checkout marked ready is not released when a later step fails" do
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")
    session.provision!

    ActionCable.server.stub(:broadcast, ->(*) { raise "cable is down" }) { perform_enqueued_jobs }

    session.reload
    assert session.ready?
    assert_nil session.error_message
    assert_equal "probe-#{session.session_id}", session.cloud_run_job_id
    assert_equal [ [ :create, session.session_id ] ], ProbeBackend.calls
  end

  test "stopping a checkout terminates it through its backend" do
    session_id = ready_checkout

    delete "/activeagents/api/sandboxes/#{session_id}"

    assert_response :success
    body = JSON.parse(response.body)
    assert body["deleted"]
    assert_equal "expired", body.dig("sandbox", "status")
    session = ActionAgent::SandboxSession.find_by!(session_id: session_id)
    # Unreachable at once, before the backend has let go.
    assert_nil session.runtime_mcp_url
    assert_nil session.runtime_mcp_token
    assert_nil ActionAgent::SandboxSession.runtime_server_entry(session.runtime_server_key, owner: nil)
    assert_equal "probe-#{session_id}", session.cloud_run_job_id

    perform_enqueued_jobs

    assert_includes ProbeBackend.calls, [ :terminate, "probe-#{session_id}" ]
    assert_nil session.reload.cloud_run_job_id
  end

  test "stopping a checkout terminates it in development too" do
    session_id = ready_checkout

    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) do
      delete "/activeagents/api/sandboxes/#{session_id}"
      assert_response :success
      perform_enqueued_jobs
    end

    assert_includes ProbeBackend.calls, [ :terminate, "probe-#{session_id}" ]
    session = ActionAgent::SandboxSession.find_by!(session_id: session_id)
    assert session.expired?
    assert_nil session.cloud_run_job_id
  end

  test "a failed terminate keeps the handle, and the reaper tries again" do
    session_id = ready_checkout
    handle = "probe-#{session_id}"
    ProbeBackend.terminate_result = false

    delete "/activeagents/api/sandboxes/#{session_id}"
    perform_enqueued_jobs
    assert_equal handle, ActionAgent::SandboxSession.find_by!(session_id: session_id).cloud_run_job_id

    ProbeBackend.terminate_result = RuntimeError.new("backend unreachable")
    assert_equal 0, ActionAgent::SandboxCleanupJob.cleanup_expired!, "nothing newly expired"
    perform_enqueued_jobs
    assert_equal handle, ActionAgent::SandboxSession.find_by!(session_id: session_id).cloud_run_job_id

    ProbeBackend.terminate_result = true
    ActionAgent::SandboxCleanupJob.cleanup_expired!
    perform_enqueued_jobs

    assert_nil ActionAgent::SandboxSession.find_by!(session_id: session_id).cloud_run_job_id
    assert_equal 3, ProbeBackend.calls.count { |call| call == [ :terminate, handle ] }
  end

  test "cleanup_expired! expires and terminates sandboxes past their expiry and returns how many" do
    stale = [ ready_checkout, ready_checkout ]
    live = ready_checkout
    ActionAgent::SandboxSession.where(session_id: stale).update_all(expires_at: 1.minute.ago)
    already = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp", expires_at: 1.hour.ago)
    already.update_columns(status: ActionAgent::SandboxSession.statuses[:expired])
    ProbeBackend.calls.clear

    count = ActionAgent::SandboxCleanupJob.cleanup_expired!

    assert_kind_of Integer, count
    assert_equal 2, count
    perform_enqueued_jobs

    assert_equal stale.map { |id| [ :terminate, "probe-#{id}" ] }.sort, ProbeBackend.calls.sort
    stale.each do |id|
      session = ActionAgent::SandboxSession.find_by!(session_id: id)
      assert session.expired?
      assert_nil session.cloud_run_job_id
      assert_nil session.runtime_mcp_url
    end
    assert ActionAgent::SandboxSession.find_by!(session_id: live).ready?
  end

  test "the index lists the caller's own live sandboxes, by type, with what Claude Code sessions need" do
    ActionAgent.user_class = "User"
    me = User.create!(email: "me-#{SecureRandom.hex(3)}@example.com", name: "Me", age: 30)
    other = User.create!(email: "other-#{SecureRandom.hex(3)}@example.com", name: "Other", age: 30)
    ActionAgent.current_user_resolver = ->(_controller) { me }

    failed = sandbox_for(me, status: :failed, created_at: 3.minutes.ago)
    ready = sandbox_for(me, status: :ready, created_at: 1.minute.ago)
    sandbox_for(me, status: :expired, created_at: 2.minutes.ago)
    browser = sandbox_for(me, status: :ready, sandbox_type: "playwright_mcp", created_at: 4.minutes.ago)
    sandbox_for(other, status: :ready)
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: CLAUDE_TOKEN, user_id: other.id)

    get "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ ready.session_id, failed.session_id ], body["sandboxes"].map { |s| s["session_id"] }
    assert_equal ActionAgent::SandboxSession::SANDBOX_TYPES, body["sandbox_types"], "what the index returned before stays"
    assert body.key?("free_tier_limits")
    assert body.key?("sample_tasks")
    assert_equal false, body["code_sessions_supported"], "the probe backend cannot run Claude Code"
    assert_equal false, body["claude_code_connected"], "another owner's Claude Code key is not the caller's"

    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: CLAUDE_TOKEN, user_id: me.id)
    ActionAgent.sandbox_service = :mock
    get "/activeagents/api/sandboxes"

    body = JSON.parse(response.body)
    assert_equal [ ready, failed, browser ].map(&:session_id), body["sandboxes"].map { |s| s["session_id"] }
    assert_equal true, body["code_sessions_supported"]
    assert_equal true, body["claude_code_connected"]
  end

  private

  def session_for(summary)
    ActionAgent::SandboxSession.find_by!(session_id: summary["session_id"])
  end

  # Starts a checkout through the API and boots it; returns its session id.
  def ready_checkout
    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/docs" }, as: :json
    assert_response :created
    perform_enqueued_jobs

    session_id = JSON.parse(response.body).dig("sandbox", "session_id")
    assert ActionAgent::SandboxSession.find_by!(session_id: session_id).ready?
    session_id
  end

  # A sandbox owned by +user+, written directly: a checkout's creation
  # checks the owner's GitHub connection, which is not what these tests are
  # about.
  def sandbox_for(user, status:, sandbox_type: "app_runtime", created_at: Time.current)
    session = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp", user_id: user.id)
    session.update_columns(
      sandbox_type: sandbox_type, repository: "acme/docs", repository_ref: "trunk",
      status: ActionAgent::SandboxSession.statuses[status], created_at: created_at
    )
    session
  end
end
