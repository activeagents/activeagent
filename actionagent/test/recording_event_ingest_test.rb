# frozen_string_literal: true

require "test_helper"

# Batches of browser events posted to a session recording: with the
# recording's ingest token, or from a dashboard session, and read back in
# time order.
class RecordingEventIngestTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::RecordingEvent.delete_all
    ActionAgent::RecordingAction.delete_all
    ActionAgent::SessionRecording.delete_all
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all
    User.delete_all

    @agent = ActionAgent::Agent.create!(name: "Browser Bot", provider: "mock", model: "mock")
    @run = @agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :running)
    @recording = ActionAgent::SessionRecording.start!(agent_run: @run, source: "agent")
    @token = @recording.issue_ingest_token!
  end

  def teardown
    ActionAgent.authentication_method = nil
    ActionAgent.recording_limits = nil
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
  end

  def events_path(recording = @recording)
    "/activeagents/api/session_recordings/#{recording.id}/events"
  end

  def batch(events, sent_at: now_ms)
    { sent_at: sent_at, events: events }.to_json
  end

  def rrweb(timestamp = now_ms, data = { "type" => 3, "data" => { "source" => 1 } })
    { kind: "rrweb", timestamp: timestamp, data: data }
  end

  def now_ms
    (Time.current.to_r * 1000).floor
  end

  # An rrweb full snapshot of a page whose elements nest +depth+ deep.
  def full_snapshot(depth)
    node = { "type" => 3, "textContent" => "leaf" }
    depth.times { node = { "type" => 2, "tagName" => "div", "attributes" => {}, "childNodes" => [ node ] } }
    { "kind" => "rrweb", "timestamp" => now_ms, "data" => { "type" => 2, "data" => { "node" => node } } }
  end

  # A batch generated as a browser would, at any depth.
  def deep_batch(events)
    JSON.generate({ "sent_at" => now_ms, "events" => events }, max_nesting: false)
  end

  def post_with_token(body, token: @token, recording: @recording)
    post events_path(recording), params: body,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  end

  def post_from_session(body, recording: @recording)
    post events_path(recording), params: body, headers: { "Content-Type" => "application/json" }
  end

  # --- the token ----------------------------------------------------------

  test "a batch posted with the recording's token is stored" do
    post_with_token batch([ rrweb, { kind: "console", timestamp: now_ms, data: { level: "error", message: "boom" } } ])

    assert_response :created
    assert_equal 2, response.parsed_body["stored"]
    assert_equal %w[console rrweb], @recording.recording_events.order(:kind).pluck(:kind)
    assert_equal 2, @recording.reload.event_count
  end

  test "only the token's digest is stored" do
    assert @token.start_with?(ActionAgent::SessionRecording::INGEST_TOKEN_PREFIX)
    stored = ActionAgent::SessionRecording.where(id: @recording.id).pick(*ActionAgent::SessionRecording.column_names).map(&:to_s)

    assert_not_includes stored, @token
    assert_equal ActionAgent::SessionRecording.ingest_token_digest(@token), @recording.reload.ingest_token_digest
  end

  test "a token is refused for any recording but its own" do
    other = ActionAgent::SessionRecording.start!(agent_run: @run, source: "agent")
    other.issue_ingest_token!

    post_with_token batch([ rrweb ]), recording: other

    assert_response :unauthorized
    assert_equal 0, other.recording_events.count
  end

  test "a token is refused once it expires" do
    travel_to(ActionAgent::SessionRecording::INGEST_TOKEN_TTL.from_now + 1.minute) do
      post_with_token batch([ rrweb ])
    end

    assert_response :unauthorized
    assert_equal 0, @recording.recording_events.count
  end

  test "a token is refused once the recording completes" do
    @recording.complete!

    post_with_token batch([ rrweb ])

    assert_response :unauthorized
  end

  test "a token expires with the recording's sandbox" do
    sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "terminal")
    recording = ActionAgent::SessionRecording.start!(sandbox_session: sandbox, source: "agent")
    token = recording.issue_ingest_token!
    assert_operator recording.ingest_token_expires_at, :<=, sandbox.expires_at

    sandbox.update!(status: :completed)
    post_with_token batch([ rrweb ]), token: token, recording: recording

    assert_response :unauthorized
  end

  test "a wrong token is refused" do
    post_with_token batch([ rrweb ]), token: "aarec_not-the-token"

    assert_response :unauthorized
  end

  test "the token cannot read the recording back" do
    ActionAgent.authentication_method = ->(_controller) { false }

    get events_path, headers: { "Authorization" => "Bearer #{@token}" }

    assert_response :unauthorized
  end

  test "without a token or a session the batch is refused" do
    ActionAgent.authentication_method = ->(_controller) { false }

    post_from_session batch([ rrweb ])

    assert_response :unauthorized
    assert_equal 0, @recording.recording_events.count
  end

  # --- what a batch may hold ----------------------------------------------

  test "a batch with a kind the server writes, or an unknown one, is refused whole" do
    %w[action human_input bogus].each do |kind|
      post_with_token batch([ rrweb, { kind: kind, timestamp: now_ms, data: {} } ])

      assert_response :unprocessable_entity, kind
      assert_match(/not accepted/, response.parsed_body["error"], kind)
    end
    post_from_session batch([ { kind: "action", timestamp: now_ms, data: {} } ])
    assert_response :unprocessable_entity, "a dashboard session may not write them either"

    assert_equal 0, @recording.recording_events.count
    assert_equal 0, @recording.reload.event_count
  end

  test "a batch without a send time is refused" do
    post_with_token({ events: [ rrweb ] }.to_json)

    assert_response :unprocessable_entity
    assert_match(/sent_at/, response.parsed_body["error"])
  end

  test "a body that is not a batch is refused" do
    post_with_token "not json"
    assert_response :unprocessable_entity

    post_with_token({ sent_at: now_ms, events: [] }.to_json)
    assert_response :unprocessable_entity
  end

  test "a full snapshot of a deeply nested page is stored and read back" do
    snapshot = full_snapshot(150)

    post_with_token deep_batch([ snapshot ])
    assert_response :created

    get events_path
    assert_response :success
    stored = JSON.parse(response.body, max_nesting: false)["events"].sole["events"].sole["data"]
    assert_equal snapshot["data"], stored
  end

  test "a batch nested deeper than the limit is refused" do
    post_with_token deep_batch([ full_snapshot(300) ])

    assert_response :unprocessable_entity
    assert_match(/nests deeper than #{ActionAgent::RecordingEvent::MAX_NESTING} levels/, response.parsed_body["error"])
    assert_equal 0, @recording.recording_events.count
  end

  # --- caps ---------------------------------------------------------------

  test "a batch over the per-batch event cap is refused and counted as dropped" do
    ActionAgent.recording_limits = { batch_events: 2 }

    post_with_token batch([ rrweb, rrweb, rrweb ])

    assert_response 413
    assert_equal 0, @recording.recording_events.count
    assert_equal 3, @recording.reload.dropped_event_count
  end

  test "a batch over the per-batch byte cap is refused and counted as dropped" do
    ActionAgent.recording_limits = { batch_bytes: 200 }

    post_with_token batch([ rrweb(now_ms, { "text" => "x" * 500 }) ])

    assert_response 413
    assert_equal 1, @recording.reload.dropped_event_count
  end

  test "a batch that would take the recording over its cap is refused and counted as dropped" do
    ActionAgent.recording_limits = { recording_events: 3 }
    post_with_token batch([ rrweb, rrweb ])
    assert_response :created

    post_with_token batch([ rrweb, rrweb ])

    assert_response 413
    @recording.reload
    assert_equal 2, @recording.event_count
    assert_equal 2, @recording.dropped_event_count
    assert_equal 2, @recording.recording_events.sum(:event_count)
  end

  # --- clocks -------------------------------------------------------------

  test "a batch from a client clock ten minutes behind is stored in server time" do
    behind = now_ms - 10.minutes.in_milliseconds

    post_with_token batch([ rrweb(behind - 500), rrweb(behind) ], sent_at: behind)

    assert_response :created
    row = @recording.recording_events.sole
    assert_in_delta Time.current, row.occurred_to, 1.second
    assert_in_delta 10.minutes.in_milliseconds, row.clock_offset_ms, 1000
    assert_equal 500, row.events.last["at"] - row.events.first["at"]
  end

  test "an event without a timestamp is placed at the batch's send time" do
    post_with_token batch([ { kind: "marker", data: { label: "checkout" } } ], sent_at: now_ms - 60_000)

    assert_in_delta Time.current, @recording.recording_events.sole.occurred_from, 1.second
  end

  # --- the dashboard session ----------------------------------------------

  test "a dashboard session posts to a recording its user owns, and no other" do
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    ActionAgent.user_class = "User"
    @recording.update!(user_id: owner.id)

    ActionAgent.current_user_resolver = ->(_controller) { stranger }
    post_from_session batch([ rrweb ])
    assert_response :not_found

    ActionAgent.current_user_resolver = ->(_controller) { owner }
    post_from_session batch([ rrweb ])
    assert_response :created
    assert_equal owner.id, @recording.recording_events.sole.user_id, "the event copies its recording's owner"
  end

  test "a cross-site post from a dashboard session is refused, and a token post is not" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post events_path, params: batch([ rrweb ]),
      headers: { "Content-Type" => "application/json", "Sec-Fetch-Site" => "cross-site" }
    assert_response :unprocessable_entity
    assert_equal "invalid_csrf_token", response.parsed_body["code"]

    post events_path, params: batch([ rrweb ]),
      headers: { "Content-Type" => "application/json", "Sec-Fetch-Site" => "cross-site", "Authorization" => "Bearer #{@token}" }
    assert_response :created
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "a completed recording takes no more events from a dashboard session" do
    @recording.complete!

    post_from_session batch([ rrweb ])

    assert_response :unprocessable_entity
  end

  # --- storage and reading back -------------------------------------------

  test "a large payload is attached through Active Storage, and kept inline without it" do
    noise = SecureRandom.alphanumeric(ActionAgent::RecordingEvent::INLINE_PAYLOAD_LIMIT * 2)

    post_with_token batch([ rrweb(now_ms, { "text" => noise }) ])
    attached = @recording.recording_events.sole
    assert_nil attached.payload
    assert attached.payload_file.attached?
    assert_equal noise, attached.events.first.dig("data", "text")

    ActionAgent::RecordingEvent.stub(:attachments_available?, false) do
      post_with_token batch([ rrweb(now_ms, { "text" => noise }) ])
    end
    inline = @recording.recording_events.order(:id).last
    assert_not_nil inline.payload
    assert_equal noise, ActionAgent::RecordingEvent.find(inline.id).events.first.dig("data", "text")
  end

  test "rrweb events read back in time order, a page at a time" do
    base = now_ms
    post_with_token batch([ rrweb(base + 2000, { "n" => 3 }) ], sent_at: base + 2000)
    post_with_token batch([ rrweb(base, { "n" => 1 }), rrweb(base + 1000, { "n" => 2 }) ], sent_at: base + 1000)
    post_with_token batch([ { kind: "console", timestamp: base, data: { message: "hi" } } ], sent_at: base)

    get events_path, params: { limit: 1 }
    first = response.parsed_body
    assert_equal [ 1, 2 ], first["events"].sole["events"].map { |event| event.dig("data", "n") }
    assert first["has_more"]

    get events_path, params: { limit: 1, after: first["next_after"] }
    second = response.parsed_body
    assert_equal [ 3 ], second["events"].sole["events"].map { |event| event.dig("data", "n") }
    assert_not second["has_more"], "the console row is not rrweb"

    get events_path, params: { kind: "console" }
    assert_equal [ "console" ], response.parsed_body["events"].map { |row| row["kind"] }
  end
end
