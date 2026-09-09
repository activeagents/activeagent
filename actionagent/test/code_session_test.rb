# frozen_string_literal: true

require "test_helper"

# A CodeSession is the row a sandboxed coding agent runs from: the repository
# it clones, the branch it pushes, the tool that drives it and the backend
# that provisions it. Every one of those is typed by a person and reaches a
# shell, so the validations here are the boundary — and the row deliberately
# carries no credential, so what it serializes matters as much as what it
# stores.
class ActionAgentCodeSessionTest < ActiveSupport::TestCase
  def setup
    ActionAgent::CodeSession.delete_all
  end

  # Both are process-wide configuration seams a test below rewrites; left
  # set, they would leak into every test that ran afterwards.
  def teardown
    ActionAgent.code_session_backends = {}
    ActionAgent.code_session_limits = nil
  end

  def build_session(**attributes)
    ActionAgent::CodeSession.new({ tool: "claude_code", backend: "mock", task: "Fix the failing tool call" }.merge(attributes))
  end

  def create_session(**attributes)
    build_session(**attributes).tap(&:save!)
  end

  # --- repository ---------------------------------------------------------

  # A person pastes whatever their browser or their git remote gave them.
  # Every one of these is the same repository, and every backend clones from
  # the same "owner/repo" form.
  test "every shape a repository is pasted in normalizes to owner/repo" do
    [
      "https://github.com/acme/app",
      "https://github.com/acme/app.git",
      "http://www.github.com/acme/app",
      "git@github.com:acme/app.git",
      "github.com/acme/app",
      "acme/app",
      "  acme/app/  "
    ].each do |pasted|
      session = build_session(repository: pasted)

      assert session.valid?, "#{pasted.inspect} should be a valid repository: #{session.errors.full_messages.inspect}"
      assert_equal "acme/app", session.repository, "#{pasted.inspect} should normalize to acme/app"
    end
  end

  # The repository is interpolated into a clone URL inside the container, so
  # a value with extra path segments — a traversal in particular — must not
  # survive validation.
  test "a repository that is not exactly one owner and one repo is rejected" do
    [ "acme/../../etc", "acme", "acme/app/extra", "/acme/app", "acme//app", "-acme/app" ].each do |pasted|
      session = build_session(repository: pasted)

      assert_not session.valid?, "#{pasted.inspect} should be rejected"
      assert_includes session.errors[:repository], "must look like owner/repo"
    end
  end

  test "a blank repository is allowed: a session can work in a scratch workspace" do
    assert build_session(repository: nil).valid?
    assert build_session(repository: "").valid?
  end

  # --- branch -------------------------------------------------------------

  test "ordinary branch names are accepted" do
    [ "main", "feature/x-1", "release/2.0", "dependabot_bump" ].each do |branch|
      session = build_session(branch: branch)

      assert session.valid?, "#{branch.inspect} should be a valid branch: #{session.errors.full_messages.inspect}"
    end
  end

  # "-rf" would be read as a flag by git, ".." climbs, and git itself refuses
  # a ref that ends in "/" or ".lock".
  test "a branch that git or a shell would misread is rejected" do
    [ "-rf", "a..b", "x/", "y.lock", "z." ].each do |branch|
      session = build_session(branch: branch)

      assert_not session.valid?, "#{branch.inspect} should be rejected"
      assert_includes session.errors[:branch], "is not a valid branch name"
    end
  end

  # --- tool and backend ---------------------------------------------------

  test "the tool must be a coding agent the catalog knows" do
    assert build_session(tool: "claude_code").valid?

    session = build_session(tool: "some_agent")

    assert_not session.valid?
    assert_includes session.errors[:tool], "is not included in the list"
  end

  # A backend name that nothing answers to would launch nothing, so it is a
  # validation failure rather than a runtime surprise.
  test "an unregistered backend is invalid until the host app registers it" do
    session = build_session(backend: "firecracker")

    assert_not session.valid?
    assert_includes session.errors[:backend], "is not a registered code session backend"

    ActionAgent.code_session_backends = { "firecracker" => "ActionAgent::MockCodeSessionBackend" }

    assert build_session(backend: "firecracker").valid?
  end

  test "the two backends the engine ships are always registered" do
    assert build_session(backend: "mock").valid?
    assert build_session(backend: "code_on_incus").valid?
    assert_not build_session(backend: nil).valid?
  end

  # --- enumerated columns -------------------------------------------------

  test "github access and network mode accept only their documented values" do
    ActionAgent::CodeSession::GITHUB_ACCESS.each do |access|
      assert build_session(github_access: access).valid?, "#{access.inspect} should be a valid github_access"
    end
    ActionAgent::CodeSession::NETWORK_MODES.each do |mode|
      assert build_session(network_mode: mode).valid?, "#{mode.inspect} should be a valid network_mode"
    end

    assert_not build_session(github_access: "admin").valid?
    assert_not build_session(network_mode: "everything").valid?
  end

  test "github_access? is false only for none" do
    assert_not build_session(github_access: "none").github_access?
    assert build_session(github_access: "read").github_access?
    assert build_session(github_access: "write").github_access?
  end

  # --- identity and expiry ------------------------------------------------

  test "every session generates its own session_id and no two share one" do
    ids = Array.new(3) { create_session.session_id }

    assert_equal 3, ids.compact.uniq.size
    ids.each { |id| assert_match(/\A[0-9a-f-]{36}\z/, id) }

    duplicate = build_session(session_id: ids.first)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:session_id], "has already been taken"
  end

  test "a supplied session_id is kept rather than overwritten" do
    session = create_session(session_id: "chosen-by-the-host-app")

    assert_equal "chosen-by-the-host-app", session.session_id
  end

  # The sandbox is reclaimed at expires_at, so the window comes from the
  # host app's limits rather than from a constant in the model.
  test "expires_at is set on create from the configured session duration" do
    ActionAgent.code_session_limits = { session_duration_minutes: 30 }

    session = create_session

    assert_in_delta 30.minutes.from_now.to_f, session.expires_at.to_f, 5
  end

  test "the default duration applies when the host app configured none" do
    session = create_session

    assert_in_delta ActionAgent.code_session_limits[:session_duration_minutes].minutes.from_now.to_f,
      session.expires_at.to_f, 5
  end

  test "an expires_at the caller set is left alone" do
    chosen = 5.minutes.from_now

    assert_in_delta chosen.to_f, create_session(expires_at: chosen).expires_at.to_f, 1
  end

  # --- status helpers -----------------------------------------------------

  test "active? covers the statuses that still hold a sandbox" do
    %w[pending provisioning ready running].each do |status|
      assert build_session(status: status).active?, "#{status} should be active"
    end
    %w[completed failed expired stopped].each do |status|
      assert_not build_session(status: status).active?, "#{status} should not be active"
    end
  end

  # A completed or failed session still has its container, so a follow-up
  # prompt is one more run rather than a new sandbox; a pending one has no
  # container yet.
  test "can_run? is true for a provisioned sandbox and false before there is one" do
    %w[ready completed failed].each do |status|
      assert create_session(status: status).can_run?, "#{status} should be runnable"
    end
    %w[pending provisioning running expired stopped].each do |status|
      assert_not create_session(status: status).can_run?, "#{status} should not be runnable"
    end
  end

  # The reclaimer may not have run yet, so time decides, not the status
  # column: a ready row past its expiry must not accept another run.
  test "a row that outlived expires_at is neither active nor runnable" do
    session = create_session(status: "ready")

    assert session.can_run?
    assert_not session.expired_by_time?

    session.update!(expires_at: 1.second.ago)

    assert session.expired_by_time?
    assert_not session.can_run?

    session.update!(status: "running")

    assert_not session.active?, "a running row past its expiry is no longer active"
  end

  test "a session with no expires_at at all has not expired" do
    session = create_session

    session.update_column(:expires_at, nil)

    assert_not session.reload.expired_by_time?
  end

  # --- append_event -------------------------------------------------------

  test "append_event writes the documented event shape" do
    session = create_session

    event = session.append_event(kind: "provision", label: "Creating sandbox", status: "started", duration_ms: 42)

    assert_equal %w[at duration_ms eid kind label status], event.keys.sort
    assert_equal "provision", event["kind"]
    assert_equal "Creating sandbox", event["label"]
    assert_equal "started", event["status"]
    assert_equal 42, event["duration_ms"]
    assert event["eid"].start_with?("#{session.id}-"), "the eid should be scoped to the row"
    assert_nothing_raised { Time.iso8601(event["at"]) }
    assert_equal [ event ], session.reload.events
  end

  test "append_event defaults to a done event and omits detail when there is none" do
    session = create_session

    event = session.append_event(kind: "run", label: "coi run")

    assert_equal "done", event["status"]
    assert_not event.key?("detail")
    assert_not event.key?("duration_ms")
  end

  # One runaway build log must not make the row unreadable in the timeline.
  test "append_event truncates a long detail" do
    session = create_session

    event = session.append_event(kind: "run", label: "coi run", detail: "x" * 5_000)

    assert_equal 1_200, event["detail"].bytesize
  end

  # Regression guard: append_event re-reads the stored column before writing,
  # so an event emitted by a job thread through another instance of the same
  # row survives an event written beside it. A plain `events << event; save`
  # would drop whichever write landed first.
  test "an event written through another instance of the same row is not lost" do
    session = create_session
    session.append_event(kind: "provision", label: "first")

    ActionAgent::CodeSession.find(session.id).append_event(kind: "run", label: "second")
    session.append_event(kind: "run", label: "third")

    assert_equal %w[first second third], session.reload.events.map { |event| event["label"] }
    assert_equal %w[first second third], session.events.map { |event| event["label"] },
      "the writing instance should also see the event it did not write"
  end

  test "events reads as an array even when the column holds something else" do
    session = create_session

    session.update_column(:events, nil)

    assert_equal [], session.reload.events
  end

  # --- as_json_summary ----------------------------------------------------

  test "as_json_summary carries the keys the dashboard polls" do
    agent = ActionAgent::Agent.create!(name: "Clara", provider: "mock", model: "mock-model")
    session = create_session(
      agent: agent, repository: "acme/app", branch: "main", github_access: "write",
      network_mode: "allowlist", model: "claude-sonnet-4-5", status: "completed",
      container_id: "action-agent-abc", exit_code: 0, started_at: 2.minutes.ago, completed_at: 1.minute.ago
    )

    summary = session.as_json_summary

    assert_equal(
      %i[
        agent backend branch completed_at container_id cost created_at error_message evaluation_run_id exit_code
        expires_at github_access id input_tokens last_activity_at limitations_count model needs_count network_mode
        output_tokens repository runtime_ms session_id started_at status task tool tool_name
      ],
      summary.keys.sort
    )
    assert_equal "Claude Code", summary[:tool_name]
    assert_equal({ id: agent.id, name: agent.name, slug: agent.slug }, summary[:agent])
    assert_in_delta 60_000, summary[:runtime_ms], 2_000
  end

  # The summary is rendered in a browser and polled by an API, so it must
  # never carry the token the session clones with, the provider key the
  # coding agent runs on, or the host path those live at — even once a brief
  # has been compiled onto the row.
  test "as_json_summary leaks no token, credential value or state path" do
    agent = ActionAgent::Agent.create!(name: "Clara", provider: "mock", model: "mock-model")
    session = create_session(agent: agent, repository: "acme/app", github_access: "write")
    session.update!(brief: ActionAgent::CodeSessionBrief.call(agent: agent, tool: "claude_code", github_access: "write"))

    assert session.brief.any?, "the brief should have been compiled for this assertion to mean anything"

    summary = session.as_json_summary
    serialized = summary.to_json

    assert_not summary.key?(:github_token)
    assert_not summary.key?(:brief)
    assert_not summary.key?(:workspace_path)
    assert_not_includes serialized, "github_token"
    assert_not_includes serialized, "secrets"
    assert_not_includes serialized, "ANTHROPIC_API_KEY"
  end

  test "needs_count and limitations_count read a brief that was never compiled" do
    session = create_session

    assert_equal 0, session.needs_count
    assert_equal 0, session.limitations_count
    assert_equal({}, session.brief)
  end

  test "runtime_ms needs a start and a finish" do
    session = create_session(started_at: nil, completed_at: 1.minute.ago)

    assert_nil session.runtime_ms

    session.update!(started_at: 2.minutes.ago, completed_at: nil, last_activity_at: nil)

    assert_nil session.runtime_ms

    session.update!(last_activity_at: 1.minute.ago)

    assert_in_delta 60_000, session.runtime_ms, 2_000
  end

  # --- transcript ---------------------------------------------------------

  test "a transcript is capped so one runaway log cannot make the row unreadable" do
    session = create_session

    session.update!(transcript: "x" * (ActionAgent::CodeSession::MAX_TRANSCRIPT_BYTES + 50_000))

    assert_equal ActionAgent::CodeSession::MAX_TRANSCRIPT_BYTES, session.reload.transcript.bytesize
  end

  # The cap is in bytes, so it can land mid-character; the value is scrubbed
  # afterwards, which is what keeps the column valid UTF-8 and renderable.
  test "capping a multibyte transcript still leaves valid UTF-8" do
    session = create_session

    session.update!(transcript: "é" * ActionAgent::CodeSession::MAX_TRANSCRIPT_BYTES)

    assert session.reload.transcript.valid_encoding?
    assert_operator session.transcript.bytesize, :<=, ActionAgent::CodeSession::MAX_TRANSCRIPT_BYTES
  end

  test "a nil transcript stays nil rather than becoming an empty string" do
    session = create_session(transcript: "something")

    session.update!(transcript: nil)

    assert_nil session.reload.transcript
  end
end
