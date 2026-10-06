# frozen_string_literal: true

require "test_helper"

# Tickets into a sandbox browser's live view (BrowserLiveTicket): who may get
# one, and that the browser sidecar can check what is issued.
class BrowserLiveTicketTest < ActionDispatch::IntegrationTest
  LIVE_URL = "ws://127.0.0.1:4200/live"
  TOKEN = "aabrw_liveTicketBrowserToken0123456789abcdef"

  def setup
    ActionAgent::SandboxSession.delete_all
    @saved = %i[permission_checker execution_enabled].index_with { |name| ActionAgent.public_send(name) }
    @sandbox = running_sandbox
  end

  def teardown
    @saved.each { |name, value| ActionAgent.public_send("#{name}=", value) }
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.account_class = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.multi_tenant = false
  end

  test "issues the ticket the sidecar's own test accepts" do
    sandbox = ActionAgent::SandboxSession.new(session_id: "7f9a2c1e-4b5d-4e6f-8a9b-0c1d2e3f4a5b",
      browser_token: "browser-token-0123456789abcdef0123456789")
    user = Struct.new(:id, :name).new(42, "Ada")

    issued = ActionAgent::BrowserLiveTicket.issue(sandbox, user: user, mode: "control", now: Time.zone.at(1_790_000_000),
      jti: "jti-0123456789abcdef")

    # browser-sidecar/test/live-ticket.test.mjs verifies this same string.
    assert_equal "eyJ2IjoxLCJzaWQiOiI3ZjlhMmMxZS00YjVkLTRlNmYtOGE5Yi0wYzFkMmUzZjRhNWIiLCJzdWIiOiI0MiIsIm5hbWUiOiJBZGEiLCJtb2RlIjoiY29udHJvbCIs" \
      "ImlhdCI6MTc5MDAwMDAwMCwiZXhwIjoxNzkwMDAwMDMwLCJqdGkiOiJqdGktMDEyMzQ1Njc4OWFiY2RlZiJ9.-RYb5JgaJwTpXeuDO5HUfjBe6UlLEvcY4W0ObBzHIWQ",
      issued[:ticket]
    assert_equal Time.zone.at(1_790_000_030), issued[:expires_at]
  end

  test "a view ticket needs only access to the sandbox, and lives 30 seconds" do
    ActionAgent.permission_checker = ->(*) { flunk "a view ticket does not ask the permission checker" }

    post tickets_path, params: { mode: "view" }, as: :json

    assert_response :created, response.body
    body = response.parsed_body
    assert_equal [ "view", LIVE_URL ], body.values_at("mode", "url")
    assert_equal "no-store", response.headers["Cache-Control"]
    claims = verified_claims(body["ticket"])
    assert_equal [ 1, @sandbox.session_id, "view", nil, nil ], claims.values_at("v", "sid", "mode", "sub", "name")
    assert_equal 30, claims["exp"] - claims["iat"]
    assert_operator claims["iat"], :<=, Time.current.to_i
    assert_equal Time.zone.at(claims["exp"]).iso8601, body["expires_at"]
    assert_match(/\A[\w-]{16,64}\z/, claims["jti"])
  end

  test "view is the default mode, and every ticket is a new one" do
    ids = 2.times.map do
      post tickets_path, as: :json
      assert_response :created
      claims = verified_claims(response.parsed_body["ticket"])
      assert_equal "view", claims["mode"]
      claims["jti"]
    end

    assert_equal 2, ids.uniq.size
  end

  test "a control ticket asks whether the user may take over this browser, and names them" do
    user = signed_in_user
    asked = []
    ActionAgent.permission_checker = ->(*args) { asked << args && true }

    post tickets_path, params: { mode: "control" }, as: :json

    assert_response :created, response.body
    assert_equal [ [ user, :take_over_browser, @sandbox ] ], asked
    claims = verified_claims(response.parsed_body["ticket"])
    assert_equal [ "control", user.id.to_s, "Ada" ], claims.values_at("mode", "sub", "name")
  end

  test "a control ticket the permission checker denies is a 403, and a view ticket is still issued" do
    signed_in_user
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :take_over_browser }

    post tickets_path, params: { mode: "control" }, as: :json
    assert_response :forbidden
    assert_equal "take_over_browser", response.parsed_body["permission"]
    assert_nil response.parsed_body["ticket"]

    post tickets_path, params: { mode: "view" }, as: :json
    assert_response :created
  end

  test "no control ticket is issued while execution is off" do
    ActionAgent.execution_enabled = false

    post tickets_path, params: { mode: "control" }, as: :json
    assert_response :forbidden

    post tickets_path, params: { mode: "view" }, as: :json
    assert_response :created
  end

  test "a browser that is not running, or has no live view, has no ticket to give" do
    @sandbox.update!(browser_live_url: nil)
    post tickets_path, as: :json
    assert_response :conflict
    assert_match(/no live view/, response.parsed_body["error"])

    @sandbox.update!(browser_live_url: LIVE_URL, browser_status: "stopped")
    post tickets_path, as: :json
    assert_response :conflict
    assert_equal "stopped", response.parsed_body.dig("browser", "status")
  end

  test "an unknown mode is refused" do
    post tickets_path, params: { mode: "admin" }, as: :json

    assert_response :unprocessable_entity
    assert_match(/mode must be one of view, control/, response.parsed_body["error"])
  end

  test "another owner's sandbox has no ticket to give" do
    ActionAgent.user_class = "User"
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    @sandbox.update_columns(user_id: owner.id)
    ActionAgent.current_user_resolver = ->(_controller) { stranger }

    post tickets_path, as: :json

    assert_response :not_found
  end

  private

  def tickets_path(sandbox = @sandbox)
    "/activeagents/api/sandboxes/#{sandbox.session_id}/browser/tickets"
  end

  def signed_in_user
    ActionAgent.user_class = "User"
    user = User.create!(email: "ada-#{SecureRandom.hex(3)}@example.com", name: "Ada", age: 36)
    @sandbox.update_columns(user_id: user.id)
    ActionAgent.current_user_resolver = ->(_controller) { user }
    user
  end

  # The ticket's claims, after checking its signature the way the sidecar
  # does.
  def verified_claims(ticket)
    payload, signature = ticket.split(".")
    key = OpenSSL::HMAC.digest("SHA256", TOKEN, ActionAgent::BrowserLiveTicket::CONTEXT)
    expected = Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", key, payload), padding: false)
    assert ActiveSupport::SecurityUtils.secure_compare(expected, signature), "the ticket is signed with the browser's key"

    JSON.parse(Base64.urlsafe_decode64(payload))
  end

  def running_sandbox
    sandbox = ActionAgent::SandboxSession.new(
      session_id: SecureRandom.uuid, sandbox_type: "app_runtime", repository: "acme/shop", repository_ref: "main"
    )
    sandbox.save!(validate: false)
    sandbox.mark_ready!(cloud_run_url: "http://127.0.0.1:4100", runtime_mcp_url: "http://127.0.0.1:4100/activeagents/mcp",
      runtime_mcp_token: "runtime-token-0123456789")
    sandbox.update!(browser_status: "running", browser_mode: "headless", browser_token: TOKEN,
      browser_mcp_url: "http://127.0.0.1:4200/mcp", browser_live_url: LIVE_URL, browser_started_at: Time.current)
    sandbox
  end
end
