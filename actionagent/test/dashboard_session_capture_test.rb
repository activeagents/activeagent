# frozen_string_literal: true

require "test_helper"

# The Run Agent workbench records a person's view of a conversation into the
# conversation's dashboard recording. The owner's stored credentials are
# masked in every batch a dashboard session posts, and a host can turn the
# capture off. DashboardCredentialsTest covers the page carrying none.
class DashboardSessionCaptureTest < ActionDispatch::IntegrationTest
  PROVIDER_KEY = "sk-capture-provider-key-0123456789"
  TELEMETRY_KEY = "tk-capture-telemetry-key-0123456789"

  def setup
    ActionAgent::RecordingEvent.delete_all
    ActionAgent::SessionRecording.delete_all
    ActionAgent::AgentContext.delete_all
    ActionAgent::ProviderKey.delete_all
    ActionAgent::ApiKey.delete_all
    ActionAgent::Agent.delete_all
    User.delete_all
  end

  def teardown
    ActionAgent.capture_dashboard_sessions = true
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
  end

  # A signed-in user who owns an agent with one conversation, in a
  # single-tenant install whose owners are users.
  def sign_in
    ActionAgent.user_class = "User"
    @me = create_user("me", telemetry_api_key: TELEMETRY_KEY)
    ActionAgent.current_user_resolver = ->(_controller) { @me }
    @agent = ActionAgent::Agent.create!(name: "Support Bot", provider: "mock", model: "mock", user_id: @me.id)
    @context = create_context(@agent)
  end

  # A user of a tenant whose telemetry key is TELEMETRY_KEY. The dummy app has
  # no Account, so the tenant is a User, and agents are owned through it.
  def sign_in_to_account
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    ActionAgent.multi_tenant = true
    @me = create_user("me")
    @account = create_user("account", telemetry_api_key: TELEMETRY_KEY)
    ActionAgent.current_user_resolver = ->(_controller) { @me }
    ActionAgent.current_account_resolver = ->(_controller) { @account }
    @agent = ActionAgent::Agent.create!(name: "Support Bot", provider: "mock", model: "mock", user_id: @account.id)
    @context = create_context(@agent)
  end

  def create_user(name, telemetry_api_key: nil)
    user = User.create!(email: "#{name}-#{SecureRandom.hex(3)}@example.com", name: name.capitalize, age: 30)
    user.define_singleton_method(:telemetry_api_key) { telemetry_api_key } if telemetry_api_key
    user
  end

  def create_context(agent)
    ActionAgent::AgentContext.create!(contextable: agent, agent_name: "SupportBot", action_name: "ask")
  end

  def dashboard_props
    get "/activeagents/dashboard"
    assert_response :success
    Nokogiri::HTML(response.body).at("#active-agent-dashboard")["data-props"]
  end

  def start_recording(context = @context)
    post "/activeagents/api/session_recordings", params: { agent_context_id: context.id }.to_json,
      headers: { "Content-Type" => "application/json" }
    response.parsed_body.dig("recording", "id")
  end

  # Posts +events+ as the dashboard does: a text/plain body, so Rails does
  # not parse it into params.
  def post_batch(recording_id, events)
    post "/activeagents/api/session_recordings/#{recording_id}/events",
      params: JSON.generate({ "sent_at" => now_ms, "recording_events" => events }, max_nesting: false),
      headers: { "Content-Type" => "text/plain" }
  end

  def stored_events(recording_id)
    get "/activeagents/api/session_recordings/#{recording_id}/events"
    assert_response :success
    response.body
  end

  def now_ms
    (Time.current.to_r * 1000).floor
  end

  # An rrweb full snapshot showing +texts+ in a code element whose title is
  # +title+.
  def snapshot(*texts, title: "")
    code = { "type" => 2, "tagName" => "code", "attributes" => { "title" => title },
             "childNodes" => texts.map { |text| { "type" => 3, "textContent" => text } } }
    { "kind" => "rrweb", "timestamp" => now_ms, "data" => { "type" => 2, "data" => { "node" => { "type" => 0, "childNodes" => [ code ] } } } }
  end

  # An rrweb mutation changing a text node to +text+.
  def text_mutation(text)
    { "kind" => "rrweb", "timestamp" => now_ms, "data" => { "type" => 3, "data" => { "source" => 0, "texts" => [ { "id" => 7, "value" => text } ] } } }
  end

  # --- the dashboard page -------------------------------------------------

  test "the page names the recorder bundle, and none when capture is off" do
    assert_equal "/action_agent_recorder.js", JSON.parse(dashboard_props).dig("meta", "recorderUrl")

    ActionAgent.capture_dashboard_sessions = false

    assert_nil JSON.parse(dashboard_props).dig("meta", "recorderUrl")
  end

  # --- the workbench's recording ------------------------------------------

  test "a conversation gets one dashboard recording while it records" do
    sign_in

    id = start_recording
    assert_response :created
    recording = ActionAgent::SessionRecording.find(id)
    assert_equal [ "dashboard", @context.id, @me.id ], [ recording.source, recording.agent_context_id, recording.user_id ]

    assert_equal id, start_recording
    assert_response :ok

    other = start_recording(create_context(@agent))
    assert_response :created
    assert_not_equal id, other, "another conversation gets a recording of its own"

    recording.complete!
    assert_not_equal id, start_recording, "a completed recording takes no more batches, so another one starts"
    assert_response :created
  end

  test "a conversation of an agent the caller cannot reach gets no recording" do
    sign_in
    stranger = create_user("stranger")
    theirs = create_context(ActionAgent::Agent.create!(name: "Theirs", provider: "mock", model: "mock", user_id: stranger.id))

    start_recording(theirs)

    assert_response :not_found
    assert_empty ActionAgent::SessionRecording.all
  end

  test "a caller who resolves to no owner of recordings gets none" do
    sign_in_to_account
    ActionAgent.current_user_resolver = ->(_controller) { nil }

    start_recording

    assert_response :unauthorized
    assert_empty ActionAgent::SessionRecording.all
  end

  test "a recording needs a conversation" do
    sign_in

    post "/activeagents/api/session_recordings", params: {}.to_json, headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
  end

  test "with capture off no recording starts and dashboard batches are refused, while token batches are not" do
    sign_in
    recording = ActionAgent::SessionRecording.start!(agent_context: @context, source: "dashboard", owner: @me)
    ActionAgent.capture_dashboard_sessions = false

    start_recording
    assert_response :forbidden
    assert_equal "capture_disabled", response.parsed_body["code"]

    post_batch(recording.id, [ snapshot("hello") ])
    assert_response :forbidden
    assert_equal "capture_disabled", response.parsed_body["code"]
    assert_equal 0, recording.recording_events.count

    post "/activeagents/api/session_recordings/#{recording.id}/events",
      params: { sent_at: now_ms, recording_events: [ snapshot("hello") ] }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{recording.issue_ingest_token!}" }
    assert_response :created
  end

  # --- scrubbing ----------------------------------------------------------

  test "a batch carrying one of the owner's provider keys is stored with it masked" do
    sign_in
    ActionAgent::ProviderKey.create!(provider: "openai", credential: PROVIDER_KEY, user_id: @me.id)
    id = start_recording

    post_batch(id, [ snapshot("Using #{PROVIDER_KEY} now", title: PROVIDER_KEY), text_mutation(PROVIDER_KEY) ])

    assert_response :created
    events = stored_events(id)
    assert_not_includes events, PROVIDER_KEY
    assert_includes events, "Using #{ActionAgent::SecretScrubber::MASK} now"
  end

  test "another owner's provider key is not theirs to mask" do
    sign_in
    stranger = create_user("stranger")
    ActionAgent::ProviderKey.create!(provider: "openai", credential: PROVIDER_KEY, user_id: stranger.id)
    id = start_recording

    post_batch(id, [ snapshot(PROVIDER_KEY) ])

    assert_includes stored_events(id), PROVIDER_KEY
  end

  test "a recording spanning API key creation holds neither the key nor the telemetry key" do
    sign_in_to_account
    id = start_recording
    post_batch(id, [ snapshot("Run Agent") ])
    assert_response :created

    post "/activeagents/api/api_keys", params: { name: "ci" }
    assert_response :created
    token = response.parsed_body.dig("api_key", "token")
    assert token.present?

    post_batch(id, [ snapshot("Key created: #{token}", title: TELEMETRY_KEY), text_mutation("#{token} #{TELEMETRY_KEY}") ])
    assert_response :created

    events = stored_events(id)
    assert_equal 3, ActionAgent::SessionRecording.find(id).event_count
    assert_not_includes events, token
    assert_not_includes events, TELEMETRY_KEY
  end

  test "a batch is not stored when the owner's credentials cannot be read" do
    sign_in
    id = start_recording

    ActionAgent::GithubConnection.stub(:all, -> { raise ActiveRecord::Encryption::Errors::Decryption }) do
      post_batch(id, [ snapshot("hello") ])
    end

    assert_response :service_unavailable
    assert_equal "credential_check_failed", response.parsed_body["code"]
    assert_equal 0, ActionAgent::RecordingEvent.count
  end

  test "a text/plain batch nested deeper than request parameters allow is stored" do
    sign_in
    id = start_recording
    node = { "type" => 3, "textContent" => "leaf" }
    60.times { node = { "type" => 2, "tagName" => "div", "attributes" => {}, "childNodes" => [ node ] } }

    post_batch(id, [ { "kind" => "rrweb", "timestamp" => now_ms, "data" => { "type" => 2, "data" => { "node" => node } } } ])

    assert_response :created
  end
end
