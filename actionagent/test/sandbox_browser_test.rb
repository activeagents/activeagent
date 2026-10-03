# frozen_string_literal: true

require "test_helper"

# A checkout sandbox's browser through the API (SandboxBrowser): started by
# its backend with a token and a recording of its own, metered in minutes,
# and stopped by DELETE, by the sandbox's expiry, or by the reaper. The
# backend is a double that records what it is asked.
class SandboxBrowserTest < ActionDispatch::IntegrationTest
  MCP_URL = "http://127.0.0.1:4200/mcp"

  class BrowserBackend
    class << self
      attr_accessor :calls, :start_error, :modes, :stop_result, :at_stop

      def reset!
        self.calls = []
        self.start_error = nil
        self.modes = %i[headless headed]
        self.stop_result = true
        self.at_stop = []
      end
    end

    def create_sandbox(_session) = {}
    def status(_handle) = { status: "running" }
    def terminate(_handle) = true
    def list_sandboxes = []
    def cleanup_expired = 0
    def browser_modes = self.class.modes

    def start_browser(sandbox, mode:)
      self.class.calls << [ :start_browser, sandbox.session_id, mode, sandbox.browser_launch.deep_dup ]
      error = self.class.start_error
      raise error.call(sandbox.browser_launch) if error

      { mcp_url: MCP_URL, mcp_token: sandbox.browser_launch[:token] }
    end

    # Also notes whether the sandbox and its browser's recording were still
    # live when the browser was stopped, which is when its last events post.
    def stop_browser(sandbox)
      self.class.calls << [ :stop_browser, sandbox.session_id ]
      live = ActionAgent::SandboxSession.active.where(id: sandbox.id).exists?
      self.class.at_stop << { sandbox_live: live, recordings: ActionAgent::SessionRecording.where(sandbox_session_id: sandbox.id).pluck(:status) }
      self.class.stop_result
    end
  end

  def setup
    ActionAgent::RecordingEvent.delete_all
    ActionAgent::SessionRecording.delete_all
    ActionAgent::SandboxSession.delete_all
    BrowserBackend.reset!
    @saved = %i[sandbox_backends sandbox_service quota_checker usage_recorder execution_enabled].index_with do |name|
      ActionAgent.public_send(name)
    end
    ActionAgent.sandbox_backends = { "browser" => BrowserBackend.name }
    ActionAgent.sandbox_service = :browser
    @sandbox = live_sandbox
  end

  def teardown
    @saved.each { |name, value| ActionAgent.public_send("#{name}=", value) }
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
  end

  test "a browser starts headless on the backend, with a token and a recording of its own" do
    post browser_path, as: :json

    assert_response :created, response.body
    @sandbox.reload
    expected = { "mode" => "headless", "status" => "running", "server_key" => "browser:#{@sandbox.session_id}",
                 "started_at" => @sandbox.browser_started_at.iso8601, "live_url" => nil }
    assert_equal expected, response.parsed_body["browser"]
    assert_equal "running", @sandbox.browser_status
    assert_equal MCP_URL, @sandbox.browser_mcp_url

    _verb, session_id, mode, launch = BrowserBackend.calls.sole
    assert_equal [ @sandbox.session_id, :headless ], [ session_id, mode ]
    assert_equal @sandbox.browser_token, launch[:token]
    assert_match(/\Aaabrw_\w{40}\z/, launch[:token])
    assert_equal "http://127.0.0.1:4100", launch[:app_url]
    assert_equal [], launch[:capabilities]
    assert_equal (@sandbox.expires_at - 30.seconds).to_i, launch[:stop_at].to_i, "it stops itself before the sandbox expires"

    recording = ActionAgent::SessionRecording.sole
    assert_equal [ @sandbox.id, "agent" ], [ recording.sandbox_session_id, recording.source ]
    assert recording.recording?
    assert_equal "http://www.example.com/activeagents/api/session_recordings/#{recording.id}/events", launch.dig(:recording, :url)
    assert recording.ingest_token_valid?(launch.dig(:recording, :token))
    assert_equal ActionAgent::RecordingEvent.limits.slice(:batch_events, :batch_bytes), launch[:recording].slice(:batch_events, :batch_bytes)
    assert_nil @sandbox.browser_launch, "the launch settings are not kept"
  end

  test "the browser token is encrypted at rest and never serialized or shown" do
    post browser_path, as: :json
    token = @sandbox.reload.browser_token

    stored = ActionAgent::SandboxSession.connection.select_value(
      "SELECT browser_token FROM #{ActionAgent::SandboxSession.table_name} WHERE id = #{@sandbox.id}"
    )
    assert_not_includes stored, token
    [ @sandbox.to_json, @sandbox.as_json.to_s, @sandbox.details.to_json, response.body ].each do |serialized|
      assert_not_includes serialized, token
    end
    [ @sandbox.details.to_json, response.body ].each { |shown| assert_not_includes shown, MCP_URL }

    get "/activeagents/api/sandboxes/#{@sandbox.session_id}"
    assert_not_includes response.body, token
    assert_equal "running", response.parsed_body.dig("sandbox", "browser", "status")

    get browser_path
    assert_response :success
    assert_equal "browser:#{@sandbox.session_id}", response.parsed_body.dig("browser", "server_key")
  end

  test "headed mode and optional tool groups reach the backend" do
    post browser_path, params: { mode: "headed", capabilities: [ "testing" ] }, as: :json

    assert_response :created, response.body
    _verb, _session_id, mode, launch = BrowserBackend.calls.sole
    assert_equal :headed, mode
    assert_equal [ "testing" ], launch[:capabilities]
    assert_equal "headed", @sandbox.reload.browser_mode
  end

  test "a headed browser is refused where the backend cannot show a window, and nothing starts" do
    BrowserBackend.modes = [ :headless ]

    post browser_path, params: { mode: "headed" }, as: :json

    assert_response :unprocessable_entity
    assert_match(/cannot show a browser window; start the browser headless/, response.parsed_body["error"])
    assert_empty BrowserBackend.calls
    assert_nil @sandbox.reload.browser_status
  end

  test "a backend without browsers refuses one" do
    ActionAgent.sandbox_service = :mock

    post browser_path, as: :json

    assert_response :unprocessable_entity
    assert_match(/mock sandbox backend cannot run a browser/, response.parsed_body["error"])
  end

  test "a start is refused for a sandbox that cannot run a browser now, or with settings it does not know" do
    other = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp", status: :ready, cloud_run_url: "http://127.0.0.1:9")
    post "/activeagents/api/sandboxes/#{other.session_id}/browser", as: :json
    assert_match(/Only a checkout sandbox runs a browser/, response.parsed_body["error"])

    @sandbox.update!(status: :provisioning)
    post browser_path, as: :json
    assert_match(/The sandbox is provisioning/, response.parsed_body["error"])
    @sandbox.update!(status: :ready)

    post browser_path, params: { mode: "kiosk" }, as: :json
    assert_match(/mode must be one of headless, headed/, response.parsed_body["error"])

    post browser_path, params: { capabilities: [ "devtools" ] }, as: :json
    assert_match(/Unknown browser capabilities: devtools/, response.parsed_body["error"])

    assert_response :unprocessable_entity
    assert_empty BrowserBackend.calls
  end

  test "a second start while a browser runs is refused" do
    post browser_path, as: :json
    post browser_path, as: :json

    assert_response :unprocessable_entity
    assert_match(/already running/, response.parsed_body["error"])
    assert_equal 1, BrowserBackend.calls.size
  end

  test "a quota checker that denies browser minutes stops the start with its payload" do
    asked = []
    ActionAgent.quota_checker = lambda do |owner, kind|
      asked << [ owner, kind ]
      { message: "No browser minutes left", browser_minutes_left: 0 } if kind == :browser_minutes
    end

    post browser_path, as: :json

    assert_response :payment_required
    assert_equal "No browser minutes left", response.parsed_body["message"]
    assert_equal 0, response.parsed_body["browser_minutes_left"]
    assert_equal [ [ nil, :browser_minutes ] ], asked
    assert_empty BrowserBackend.calls
  end

  test "stopping the browser asks the backend, records the minutes it ran and completes its recording" do
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind, quantity) { recorded << [ owner, kind, quantity ] }
    post browser_path, as: :json

    travel 150.seconds do
      delete browser_path, as: :json
    end

    assert_response :success
    assert_equal "stopped", response.parsed_body.dig("browser", "status")
    assert_nil response.parsed_body.dig("browser", "server_key")
    assert_equal [ :stop_browser, @sandbox.session_id ], BrowserBackend.calls.last
    assert_equal [ [ nil, :browser_minutes, 3 ] ], recorded
    @sandbox.reload
    assert_nil @sandbox.browser_token
    assert_nil @sandbox.browser_mcp_url
    assert ActionAgent::SessionRecording.sole.completed?

    delete browser_path, as: :json
    assert_response :success
    assert_equal 1, recorded.size, "a stopped browser is not counted twice"
  end

  test "a usage recorder that takes two arguments is called without the minutes" do
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind) { recorded << [ owner, kind ] }
    post browser_path, as: :json

    delete browser_path, as: :json

    assert_equal [ [ nil, :browser_minutes ] ], recorded
  end

  test "a browser the backend cannot stop stays running" do
    post browser_path, as: :json
    BrowserBackend.stop_result = false

    delete browser_path, as: :json

    assert_response :unprocessable_entity
    assert_equal "running", @sandbox.reload.browser_status
  end

  test "terminating the sandbox stops its browser while its recording still takes events, and counts its minutes" do
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind, quantity) { recorded << [ owner, kind, quantity ] }
    post browser_path, as: :json

    perform_enqueued_jobs do
      delete "/activeagents/api/sandboxes/#{@sandbox.session_id}", as: :json
    end

    assert_response :success
    assert_equal({ sandbox_live: true, recordings: [ "recording" ] }, BrowserBackend.at_stop.first)
    assert_equal [ [ nil, :browser_minutes, 1 ] ], recorded
    assert @sandbox.reload.expired?
    assert_equal "stopped", @sandbox.browser_status
    assert ActionAgent::SessionRecording.sole.completed?
  end

  test "terminating the sandbox still expires it when its browser cannot be stopped" do
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind, quantity) { recorded << [ owner, kind, quantity ] }
    post browser_path, as: :json
    BrowserBackend.stop_result = false

    delete "/activeagents/api/sandboxes/#{@sandbox.session_id}", as: :json

    assert_response :success
    assert @sandbox.reload.expired?
    assert_equal "stopped", @sandbox.browser_status, "no run reaches it any more"
    assert_equal [ [ nil, :browser_minutes, 1 ] ], recorded
    assert_enqueued_with(job: ActionAgent::SandboxCleanupJob, args: [ @sandbox.id ])
  end

  test "the reaper stops the browser of a sandbox past its expiry, counting the minutes to when it stopped itself" do
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind, quantity) { recorded << [ owner, kind, quantity ] }
    post browser_path, as: :json

    travel ActionAgent::SandboxSession::APP_RUNTIME_SESSION_DURATION + 1.minute do
      perform_enqueued_jobs { ActionAgent::SandboxCleanupJob.cleanup_expired! }
    end

    assert @sandbox.reload.expired?
    assert_equal "stopped", @sandbox.browser_status
    assert_equal [ [ nil, :browser_minutes, 120 ] ], recorded
    assert_includes BrowserBackend.calls, [ :stop_browser, @sandbox.session_id ]
    assert_equal [ false ], BrowserBackend.at_stop.map { |seen| seen[:sandbox_live] }, "past its expiry, it is left to the cleanup job"
  end

  test "a reaper that runs a day late counts no more minutes than the browser ran" do
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind, quantity) { recorded << [ owner, kind, quantity ] }
    post browser_path, as: :json

    travel ActionAgent::SandboxSession::APP_RUNTIME_SESSION_DURATION + 1.day do
      ActionAgent::SandboxCleanupJob.cleanup_expired!
    end

    assert_equal [ [ nil, :browser_minutes, 120 ] ], recorded
  end

  test "a browser is not started for a sandbox about to expire" do
    @sandbox.update_columns(expires_at: 20.seconds.from_now)

    post browser_path, as: :json

    assert_response :unprocessable_entity
    assert_match(/expires too soon to start a browser/, response.parsed_body["error"])
    assert_empty BrowserBackend.calls
  end

  test "a backend that fails to start the browser fails it, without its token in the message" do
    BrowserBackend.start_error = ->(launch) { RuntimeError.new("chromium crashed holding #{launch[:token]}") }

    post browser_path, as: :json

    assert_response :unprocessable_entity
    message = response.parsed_body["error"]
    assert_match(/The browser did not start: chromium crashed holding \[REDACTED\]/, message)
    assert_equal "failed", response.parsed_body.dig("browser", "status")
    @sandbox.reload
    assert_nil @sandbox.browser_token
    assert ActionAgent::SessionRecording.sole.failed?

    BrowserBackend.start_error = nil
    post browser_path, as: :json
    assert_response :created, "a failed browser can be started again"
  end

  test "another owner's sandbox has no browser to start" do
    ActionAgent.user_class = "User"
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    @sandbox.update_columns(user_id: owner.id)
    ActionAgent.current_user_resolver = ->(_controller) { stranger }

    post browser_path, as: :json

    assert_response :not_found
    assert_empty BrowserBackend.calls
  end

  test "no browser starts while execution is off" do
    ActionAgent.execution_enabled = false

    post browser_path, as: :json

    assert_response :forbidden
    assert_empty BrowserBackend.calls
  end

  private

  def browser_path(sandbox = @sandbox)
    "/activeagents/api/sandboxes/#{sandbox.session_id}/browser"
  end

  def live_sandbox
    sandbox = ActionAgent::SandboxSession.new(
      session_id: SecureRandom.uuid, sandbox_type: "app_runtime", repository: "acme/shop", repository_ref: "main"
    )
    # The repository check reads a GitHub selection this test has no need of.
    sandbox.save!(validate: false)
    sandbox.mark_ready!(cloud_run_url: "http://127.0.0.1:4100", runtime_mcp_url: "http://127.0.0.1:4100/activeagents/mcp",
      runtime_mcp_token: "runtime-token-0123456789")
    sandbox
  end
end
