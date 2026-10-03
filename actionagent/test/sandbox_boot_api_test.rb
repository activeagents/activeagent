# frozen_string_literal: true

require "test_helper"

# How a checkout's boot is asked for and followed over the JSON API:
# POST /api/sandboxes's bootstrap options, the boot spec SandboxProvisionJob
# hands the backend, GET …/boot and …/boot_log, POST …/resume_boot, and the
# reaper releasing a failed boot's kept workspace.
class SandboxBootApiTest < ActionDispatch::IntegrationTest
  # Takes a boot spec and implements the boot verbs, recording what it was
  # asked. The orchestrator builds a backend per call, so state is on the
  # class.
  class SpecBackend
    class << self
      attr_accessor :calls, :create_error, :boot_state, :log_pages

      def reset!
        self.calls = []
        self.create_error = nil
        self.boot_state = nil
        self.log_pages = {}
      end
    end

    def create_sandbox(session, boot_config: nil)
      self.class.calls << [ :create, session.session_id, boot_config ]
      raise self.class.create_error if self.class.create_error

      created(session)
    end

    def resume_boot(session, from:)
      self.class.calls << [ :resume_boot, session.session_id, from ]
      created(session)
    end

    def boot_status(session)
      self.class.calls << [ :boot_status, session.session_id ]
      self.class.boot_state
    end

    def boot_log(session, step:, offset:, secrets:, limit: 65_536)
      self.class.calls << [ :boot_log, session.session_id, step, offset, limit ]
      text = self.class.log_pages[step] or return nil
      page = text.byteslice(offset, limit).to_s
      { step: step, offset: offset, next_offset: offset + page.bytesize, size: text.bytesize,
        eof: offset + page.bytesize >= text.bytesize, text: page }
    end

    def handle_for(session) = "spec-#{session.session_id}"

    def terminate(handle)
      self.class.calls << [ :terminate, handle ]
      true
    end

    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0

    private

    def created(session)
      { container_name: "spec-#{session.session_id}", url: "http://127.0.0.1:9", mcp_url: "http://127.0.0.1:9/activeagents/mcp",
        mcp_token: "spec-mcp-token" }
    end
  end

  # Predates boot specs: create takes the session alone.
  class PlainBackend
    class << self
      attr_accessor :calls
    end

    def create_sandbox(session)
      self.class.calls << [ :create, session.session_id ]
      { container_name: "plain-#{session.session_id}", url: "http://127.0.0.1:9", mcp_url: "http://127.0.0.1:9/activeagents/mcp" }
    end

    def terminate(_handle) = true
    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  ENGINE = {
    "activeagent" => { "source" => "rubygems", "version" => "1.9.0" },
    "actionagent" => { "source" => "rubygems", "version" => "1.9.0" }
  }.freeze

  def setup
    ActionAgent::SandboxSession.delete_all
    ActionAgent::GithubConnection.delete_all
    SpecBackend.reset!
    PlainBackend.calls = []

    @original_backends = ActionAgent.sandbox_backends
    @original_service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = { "spec" => SpecBackend.name, "plain" => PlainBackend.name }
    ActionAgent.sandbox_service = :spec

    ActionAgent::GithubConnection.create!(
      access_token: "gho_boot_api_token", github_user_id: 42, login: "octocat",
      repositories: [ { "id" => 2, "full_name" => "acme/shop", "private" => false, "default_branch" => "main" } ]
    )
  end

  def teardown
    ActionAgent.sandbox_backends = @original_backends
    ActionAgent.sandbox_service = @original_service
    ActionAgent.execution_enabled = true
  end

  test "a checkout is bootstrapped when its lock lacks the engine, unless asked otherwise" do
    session_id = start_checkout

    spec = created_spec(session_id)
    assert_equal "bootstrap", spec["kind"]
    assert_equal "without_engine", spec["apply"], "the backend decides once it has the checkout's Gemfile.lock"
    assert_equal "/", spec["start_url"]
    assert_equal false, spec["keep_on_failure"]
    assert_equal "ready", ActionAgent::SandboxSession.find_by!(session_id: session_id).status
  end

  test "bootstrap, start_url and keep_on_failure reach the spec, and the job holds nothing else" do
    post "/activeagents/api/sandboxes", as: :json,
      params: { sandbox_type: "app_runtime", repository: "acme/shop", bootstrap: "always", start_url: "/up", keep_on_failure: true }
    assert_response :created
    session_id = JSON.parse(response.body).dig("sandbox", "session_id")

    job = enqueued_jobs.find { |entry| entry["job_class"] == "ActionAgent::SandboxProvisionJob" }
    assert_equal({ "bootstrap" => "always", "start_url" => "/up", "keep_on_failure" => true },
      job[:args].last["boot"].except("_aj_ruby2_keywords", "_aj_symbol_keys"))

    perform_enqueued_jobs
    spec = created_spec(session_id)
    assert_equal [ "always", "/up", true ], spec.values_at("apply", "start_url", "keep_on_failure")
  end

  test "bootstrap never boots the checkout as its sandbox.yml says" do
    session_id = start_checkout(bootstrap: "never")

    assert_equal [ [ :create, session_id, nil ] ], SpecBackend.calls
  end

  test "malformed boot options are refused before anything is created" do
    {
      { bootstrap: "sometimes" } => "`bootstrap` must be one of auto, always, never",
      { start_url: "https://elsewhere.example" } => "`start_url` must be a path on the app, such as /",
      { start_url: "//elsewhere.example" } => "`start_url` must be a path on the app, such as /"
    }.each do |options, message|
      post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/shop", **options }, as: :json

      assert_response :unprocessable_entity
      assert_equal [ message ], JSON.parse(response.body)["errors"]
    end
    assert_equal 0, ActionAgent::SandboxSession.count
  end

  test "a backend that takes no spec boots as before, and refuses an explicit bootstrap" do
    ActionAgent.sandbox_service = :plain

    session_id = start_checkout
    assert_equal [ [ :create, session_id ] ], PlainBackend.calls
    assert_equal "ready", ActionAgent::SandboxSession.find_by!(session_id: session_id).status

    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/shop", bootstrap: "always" }, as: :json
    assert_response :unprocessable_entity
    assert_equal [ "This sandbox backend cannot bootstrap a checkout" ], JSON.parse(response.body)["errors"]
  end

  test "a bootstrap that cannot be built fails an explicit request, and auto boots without one" do
    refusal = ->(*) { raise ActionAgent::SandboxBootSpec::Invalid, "the dashboard bundles actionagent from a git URL with credentials in it" }

    auto = start_checkout(engine: refusal)
    always = start_checkout(engine: refusal, bootstrap: "always")

    assert_equal [ [ :create, auto, nil ] ], SpecBackend.calls
    failed = ActionAgent::SandboxSession.find_by!(session_id: always)
    assert failed.failed?
    assert_match(/\ASandbox boot spec is invalid: the dashboard bundles actionagent from a git URL/, failed.error_message)
  end

  test "GET boot reports the backend's steps, and whether the failed boot can be resumed" do
    session_id = failed_checkout
    SpecBackend.boot_state = {
      mode: "spec", kind: "bootstrap", failed_step: "db_prepare", kept: true,
      steps: [ { name: "checkout", status: "succeeded" }, { name: "db_prepare", status: "failed", detail: "exited with status 1" } ]
    }

    get "/activeagents/api/sandboxes/#{session_id}/boot"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "db_prepare", body.dig("boot", "failed_step")
    assert_equal %w[checkout db_prepare], body.dig("boot", "steps").map { |step| step["name"] }
    assert body["resumable"]
    assert body["logs"]

    SpecBackend.boot_state = SpecBackend.boot_state.merge(kept: false)
    get "/activeagents/api/sandboxes/#{session_id}/boot"
    assert_not JSON.parse(response.body)["resumable"]
  end

  test "GET boot answers null for a backend that reports no steps" do
    ActionAgent.sandbox_service = :plain
    session_id = start_checkout

    get "/activeagents/api/sandboxes/#{session_id}/boot"

    assert_response :success
    assert_equal({ "boot" => nil, "resumable" => false, "logs" => false }, JSON.parse(response.body))
    get "/activeagents/api/sandboxes/#{session_id}/boot_log", params: { step: "setup" }
    assert_response :not_found
  end

  test "GET boot_log pages through a step's log" do
    session_id = failed_checkout
    SpecBackend.log_pages = { "db_prepare" => "line one\nline two\n" }

    get "/activeagents/api/sandboxes/#{session_id}/boot_log", params: { step: "db_prepare", offset: 9, limit: 4 }

    assert_response :success
    assert_equal({ "step" => "db_prepare", "offset" => 9, "next_offset" => 13, "size" => 18, "eof" => false, "text" => "line" },
      JSON.parse(response.body))
    assert_equal [ :boot_log, session_id, "db_prepare", 9, 4 ], SpecBackend.calls.last

    get "/activeagents/api/sandboxes/#{session_id}/boot_log", params: { step: "db_prepare", limit: 50_000_000 }
    assert_equal 1024 * 1024, SpecBackend.calls.last.last, "a page is bounded"

    get "/activeagents/api/sandboxes/#{session_id}/boot_log", params: { step: "no_such_step" }
    assert_response :not_found
    get "/activeagents/api/sandboxes/#{session_id}/boot_log"
    assert_response :bad_request
  end

  test "POST resume_boot continues a kept boot from the step asked for" do
    session_id = failed_checkout
    SpecBackend.boot_state = { mode: "spec", kept: true, failed_step: "db_prepare", steps: [] }

    post "/activeagents/api/sandboxes/#{session_id}/resume_boot", params: { from: "install_engine" }, as: :json

    assert_response :accepted
    assert_equal "provisioning", JSON.parse(response.body).dig("sandbox", "status")
    assert_nil JSON.parse(response.body).dig("sandbox", "error_message")
    perform_enqueued_jobs
    assert_includes SpecBackend.calls, [ :resume_boot, session_id, "install_engine" ]
    session = ActionAgent::SandboxSession.find_by!(session_id: session_id)
    assert session.ready?
    assert_equal "spec-#{session_id}", session.cloud_run_job_id
  end

  test "POST resume_boot without a step resumes from the one that failed" do
    session_id = failed_checkout
    SpecBackend.boot_state = { mode: "spec", kept: true, failed_step: "db_prepare", steps: [] }

    post "/activeagents/api/sandboxes/#{session_id}/resume_boot", as: :json
    perform_enqueued_jobs

    assert_includes SpecBackend.calls, [ :resume_boot, session_id, nil ]
  end

  test "POST resume_boot refuses what it cannot resume" do
    session_id = failed_checkout

    SpecBackend.boot_state = { mode: "spec", kept: false, steps: [] }
    post "/activeagents/api/sandboxes/#{session_id}/resume_boot", as: :json
    assert_response :unprocessable_entity
    assert_match "kept no failed boot", JSON.parse(response.body)["error"]

    SpecBackend.boot_state = { mode: "spec", kept: true, steps: [] }
    ActionAgent::SandboxSession.find_by!(session_id: session_id).update_columns(expires_at: 1.minute.ago)
    post "/activeagents/api/sandboxes/#{session_id}/resume_boot", as: :json
    assert_response :unprocessable_entity
    assert_match "has not expired", JSON.parse(response.body)["error"]

    ready = start_checkout
    post "/activeagents/api/sandboxes/#{ready}/resume_boot", as: :json
    assert_response :unprocessable_entity

    post "/activeagents/api/sandboxes/#{session_id}/resume_boot", params: { from: [ "a" ] }, as: :json
    assert_response :bad_request

    ActionAgent.execution_enabled = false
    post "/activeagents/api/sandboxes/#{session_id}/resume_boot", as: :json
    assert_response :forbidden

    assert_no_enqueued_jobs(only: ActionAgent::SandboxProvisionJob)
    assert_not SpecBackend.calls.any? { |call| call.first == :resume_boot }
  end

  test "POST resume_boot refuses a backend that cannot resume" do
    ActionAgent.sandbox_service = :plain
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/shop", status: :failed)

    post "/activeagents/api/sandboxes/#{session.session_id}/resume_boot", as: :json

    assert_response :unprocessable_entity
    assert_equal "This sandbox backend cannot resume a boot", JSON.parse(response.body)["error"]
  end

  test "the reaper releases a failed checkout's kept boot once its time is up, and leaves it failed" do
    session_id = failed_checkout
    session = ActionAgent::SandboxSession.find_by!(session_id: session_id)

    ActionAgent::SandboxCleanupJob.cleanup_expired!
    perform_enqueued_jobs
    assert_not_includes SpecBackend.calls, [ :terminate, "spec-#{session_id}" ], "kept for a resume until it expires"

    session.update_columns(expires_at: 1.minute.ago)
    ActionAgent::SandboxCleanupJob.cleanup_expired!
    perform_enqueued_jobs

    assert_includes SpecBackend.calls, [ :terminate, "spec-#{session_id}" ]
    assert session.reload.failed?, "its error stays readable"

    SpecBackend.calls.clear
    session.update_columns(expires_at: 2.days.ago)
    ActionAgent::SandboxCleanupJob.cleanup_expired!
    perform_enqueued_jobs
    assert_empty SpecBackend.calls, "retried for a day after it expired"
  end

  private

  # Starts a checkout and runs its provision job, with the engine's gems
  # read as +engine+ (a value, or a callable to stub .engine_gems with).
  def start_checkout(engine: ENGINE, **options)
    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/shop", **options }, as: :json
    assert_response :created, response.body
    session_id = JSON.parse(response.body).dig("sandbox", "session_id")
    ActionAgent::SandboxBootSpec.stub(:engine_gems, engine) { perform_enqueued_jobs }
    session_id
  end

  def failed_checkout
    SpecBackend.create_error = RuntimeError.new("Sandbox db_prepare failed: `bin/rails db:prepare` exited with status 1")
    session_id = start_checkout(keep_on_failure: true)
    SpecBackend.create_error = nil
    assert ActionAgent::SandboxSession.find_by!(session_id: session_id).failed?
    session_id
  end

  def created_spec(session_id)
    call = SpecBackend.calls.find { |entry| entry.first(2) == [ :create, session_id ] }
    assert call, "the backend was asked to create #{session_id}"
    call.last
  end
end
