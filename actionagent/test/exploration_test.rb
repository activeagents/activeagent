# frozen_string_literal: true

require "test_helper"
require_relative "support/exploration_setup"

# Explorations: candidates stored scrubbed and bounded with a verdict
# against the target agent's real tools, edited, rejected and accepted into
# the project's evaluation under namespaced keys without touching any other
# scenario.
class ExplorationTest < ActiveSupport::TestCase
  include ExplorationSetup

  SUITE_EDITOR_LINES = JSON.parse(File.read(File.expand_path("../frontend/test/fixtures/suite-editor-lines.json", __dir__)))

  def setup
    reset_exploration_records!
    @project = create_explored_project!
    stub_runtime
  end

  def explore(*candidates, **attributes)
    exploration = ActionAgent::Exploration.build_for(project: @project, source: "external", status: "review", **attributes)
    exploration.save_with_candidates!(candidates)
    exploration.reload
  end

  test "candidates get ids, proposed state and a verdict against the target agent's real tools" do
    exploration = explore(
      candidate("Where is order A-17?", tools: [ "lookup_order" ], rubric: "Gives A-17's status."),
      candidate("Refund order A-17", tools: [ "refund_order", "lookup_order" ]),
      candidate("What can you do?")
    )

    rows = exploration.candidates
    assert_equal [ 1, 2, 3 ], rows.map { |row| row["id"] }
    assert_equal %w[proposed] * 3, rows.map { |row| row["state"] }
    assert_equal %w[answerable needs_tool answerable], rows.map { |row| row["verdict"] }
    assert_equal [ [], [ "refund_order" ], [] ], rows.map { |row| row["missing_tools"] }
    assert_equal "Gives A-17's status.", rows.first["notes"]
    assert_equal ActionAgent::Exploration::DEFAULT_GROUP, rows.first["group"]
    assert_equal({ "tools" => [ "lookup_order" ], "contains" => [], "not_contains" => [] }, rows.first["expectations"])
    assert_equal({ total: 3, open: 3, accepted: 0, rejected: 0, answerable: 2, needs_tool: 1, unverified: 0 }, exploration.candidate_counts)
    assert_requested(:post, RUNTIME_URL, headers: { "Authorization" => "Bearer #{RUNTIME_TOKEN}" }, at_least_times: 1) do |request|
      JSON.parse(request.body)["method"] == "tools/list"
    end
  end

  test "with the sandbox down or stopped, every verdict is unverified" do
    WebMock.reset!
    stub_runtime(fail: true)
    down = explore(candidate("Where is order A-17?", tools: [ "lookup_order" ]), candidate("Hello"))
    assert_equal %w[unverified unverified], down.candidates.map { |row| row["verdict"] }

    @project.current_sandbox_session.update!(status: :expired)
    stopped = explore(candidate("Where is order A-17?", tools: [ "lookup_order" ]))
    assert_equal "unverified", stopped.candidates.sole["verdict"]
    assert_equal({ "verdict" => "unverified", "missing_tools" => [] }, ActionAgent::Exploration.verdict([ "x" ], nil))
  end

  test "a tool missing while one of the agent's own servers failed discovery is unverified, not missing" do
    roster = { names: Set["lookup_order"], complete: false }

    assert_equal "answerable", ActionAgent::Exploration.verdict([ "lookup_order" ], roster)["verdict"]
    assert_equal "unverified", ActionAgent::Exploration.verdict([ "refund_order" ], roster)["verdict"]
  end

  test "an exploration without a project checks against its evaluation's agent" do
    agent = ActionAgent::Agent.create!(name: "Helper", provider: "mock", model: "mock-model", status: :active,
      tools: [ "search" ])
    evaluation = agent.evaluations.create!(name: "Helper suite", judge_kind: "rules",
      criteria: [ { "key" => "answered", "type" => "response_present", "config" => {} } ])
    exploration = ActionAgent::Exploration.build_for(evaluation: evaluation, source: "external", status: "review")
    exploration.save_with_candidates!([ candidate("Search the web", tools: [ "web_search" ]), candidate("Order", tools: [ "lookup_order" ]) ])

    assert_equal [ nil, evaluation.id ], [ exploration.project_id, exploration.evaluation_id ]
    assert_equal %w[answerable needs_tool], exploration.reload.candidates.map { |row| row["verdict"] }
    assert_raises(ActiveRecord::RecordInvalid) { ActionAgent::Exploration.build_for(source: "external").save! }
  end

  test "candidate text is scrubbed of the project's secrets and their encodings before it is stored" do
    encoded = [ SECRET ].pack("m0")
    exploration = explore(candidate("Pay with #{SECRET}", rubric: "Never echoes #{encoded}", contains: [ SECRET ],
      provenance: { "steps" => [ "Typed #{SECRET}" ], "urls" => [ "/pay?key=#{URI.encode_www_form_component(SECRET)}" ] }))

    stored = exploration.read_attribute_before_type_cast(:candidates).to_s
    ActionAgent::SecretScrubber.with_encodings([ SECRET ]).each { |form| assert_not_includes stored, form }
    row = exploration.candidates.sole
    assert_equal "Pay with [REDACTED]", row["prompt"]
    assert_equal "Never echoes [REDACTED]", row["notes"]
    assert_equal [ "[REDACTED]" ], row.dig("expectations", "contains")
    assert_equal [ "Typed [REDACTED]" ], row.dig("provenance", "steps")
  end

  test "a prompt, rubric or expectation over its limit is refused, and provenance is cut for display" do
    exploration = explore(candidate("Where is order A-17?", provenance: {
      "steps" => Array.new(55) { |index| "Step #{index}" }, "urls" => [ "/orders?q=#{'x' * 3_000}" ]
    }))
    provenance = exploration.candidates.sole["provenance"]
    assert_equal "[truncated: 5 more items]", provenance["steps"].last
    assert_match(/…\[truncated: \d+ more characters\]\z/, provenance["urls"].sole)

    {
      candidate("x" * 4_001) => /the prompt is longer than 4000 characters/,
      candidate("Hello", rubric: "x" * 4_001) => /the rubric is longer than 4000 characters/,
      candidate("Hello", contains: Array.new(51) { |index| "pattern #{index}" }) => /more than 50 contains entries/,
      candidate("Hello", tools: [ "t" * 201 ]) => /tools “t+\.\.\.” is longer than 200 characters/,
      candidate("Hello", not_contains: [ "p" * 201 ]) => /not contains “p+\.\.\.” is longer than 200 characters/
    }.each do |oversized, message|
      error = assert_raises(ActionAgent::Exploration::InvalidCandidate) { exploration.add_candidates!([ oversized ]) }
      assert_match message, error.message
    end
    error = assert_raises(ActionAgent::Exploration::InvalidCandidate) do
      exploration.update_candidate!(1, "contains" => Array.new(51) { |index| "pattern #{index}" })
    end
    assert_match(/more than 50 contains entries/, error.message)
    assert_equal [ 1, "proposed" ], [ exploration.reload.candidates.size, exploration.candidates.sole["state"] ]
  end

  test "a group or tool name is scrubbed before it is cut, so no part of a secret survives the cut" do
    exploration = explore(candidate("Where is order A-17?", group: "g" * 190 + SECRET, tools: [ "t" * 190 + SECRET ]))

    row = exploration.candidates.sole
    assert_equal "#{'g' * 190}[REDACTED]", row["group"]
    assert_equal [ "#{'t' * 190}[REDACTED]" ], row.dig("expectations", "tools")
    assert_not_includes exploration.read_attribute_before_type_cast(:candidates).to_s, SECRET.first(10)
  end

  test "a call, and an exploration's candidates, total at most MAX_BYTES of JSON" do
    exploration = explore(candidate("Where is order A-17?"))
    limit = ActionAgent::Exploration::MAX_BYTES
    in_the_open = Array.new(limit / 4_000 + 1) { |index| "#{index} #{'s' * 4_000}" }

    error = assert_raises(ActionAgent::Exploration::CandidateLimitExceeded) do
      exploration.add_candidates!([ candidate("Hello", provenance: { "steps" => in_the_open }) ])
    end
    assert_match(/candidates in one call may total 2 MiB/, error.message)

    # Provenance at its limits: each call is under MAX_BYTES, and the third
    # takes the stored candidates past it.
    walk = Array.new(ActionAgent::Exploration::MAX_ITEMS) { |index| "#{index} #{'s' * 2_040}" }
    big = Array.new(3) { |index| candidate("Question #{index}", provenance: { "steps" => walk, "urls" => walk, "screenshots" => walk }) }
    exploration.add_candidates!(big)
    exploration.add_candidates!(big.first(2))
    error = assert_raises(ActionAgent::Exploration::CandidateLimitExceeded) { exploration.add_candidates!(big.first(2)) }
    assert_match(/candidates may total 2 MiB of JSON.*new exploration/, error.message)
    assert_equal 6, exploration.reload.candidates.size
    assert_operator exploration.candidates.to_json.bytesize, :<=, limit
  end

  test "an exploration holds at most MAX_CANDIDATES, and an invalid batch stores nothing" do
    exploration = explore(candidate("Where is order A-17?"))
    too_many = Array.new(ActionAgent::Exploration::MAX_CANDIDATES) { |index| candidate("Question #{index}") }
    assert_raises(ActionAgent::Exploration::CandidateLimitExceeded) { exploration.add_candidates!(too_many) }
    assert_equal 1, exploration.reload.candidates.size

    assert_raises(ActionAgent::Exploration::InvalidCandidate) { exploration.add_candidates!([ { "prompt" => " " } ]) }
    assert_raises(ActionAgent::Exploration::InvalidCandidate) { exploration.add_candidates!({ "prompt" => "x" }) }
    assert_raises(ActionAgent::Exploration::InvalidCandidate) { exploration.add_candidates!([]) }
    assert_equal 1, exploration.reload.candidates.size
  end

  test "a recording in provenance is kept only when it is the exploration's own" do
    recording = ActionAgent::SessionRecording.create!(name: "demo", status: :completed)
    own = explore({ "prompt" => "Where is order A-17?", "provenance" => {
      "recording_id" => recording.id, "range" => { "from_ms" => 41_200, "to_ms" => 58_900 }, "url" => "/orders"
    } }, session_recording_id: recording.id)
    assert_equal({ "urls" => [ "/orders" ], "steps" => [], "recording_id" => recording.id,
                   "range" => { "from_ms" => 41_200, "to_ms" => 58_900 }, "screenshots" => [] }, own.candidates.sole["provenance"])

    other = explore({ "prompt" => "Where is order A-17?", "provenance" => { "recording_id" => recording.id,
                                                                             "range" => { "from_ms" => 1 } } })
    assert_equal({ "urls" => [], "steps" => [], "screenshots" => [] }, other.candidates.sole["provenance"])
  end

  test "an edit is scrubbed, checks changed tools again and marks the candidate edited; reject and reconsider" do
    exploration = explore(candidate("Where is order A-17?", tools: [ "lookup_order" ]))

    edited = exploration.update_candidate!(1, "rubric" => "Says A-17 shipped, without #{SECRET}", "tools" => [ "track_parcel" ])
    assert_equal [ "edited", "needs_tool", [ "track_parcel" ] ], edited.values_at("state", "verdict", "missing_tools")
    assert_equal "Says A-17 shipped, without [REDACTED]", edited["notes"]

    assert_equal "rejected", exploration.update_candidate!(1, "state" => "rejected")["state"]
    assert_equal "closed", exploration.reload.status
    assert_equal "proposed", exploration.update_candidate!(1, "state" => "proposed")["state"]
    assert_equal "review", exploration.reload.status

    assert_raises(ActionAgent::Exploration::InvalidCandidate) { exploration.update_candidate!(1, "state" => "accepted") }
    assert_raises(ActiveRecord::RecordNotFound) { exploration.update_candidate!(9, "prompt" => "x") }
  end

  test "accepting merges into the project's evaluation under x<exploration>_<candidate> with the rubric as notes" do
    evaluation = @project.evaluation
    evaluation.scenarios.create!(key: "orders_1", prompt: "Hand written", group: "Orders", position: 0, enabled: false)
    exploration = explore(
      candidate("Which orders shipped late?", tools: [ "find_orders" ], rubric: "Lists each\nlate order | with dates",
        group: "Orders", provenance: { "steps" => [ "Opened Orders" ] }),
      candidate("Refund A-17", tools: [ "refund_order" ])
    )

    merged = exploration.accept!([ 1 ])

    key = "x#{exploration.id}_1"
    assert_equal [ key ], merged[:added]
    scenario = evaluation.scenarios.find_by!(key: key)
    assert_equal [ "Which orders shipped late?", "Orders", "Lists each late order / with dates", { "tools" => [ "find_orders" ] } ],
      [ scenario.prompt, scenario.group, scenario.notes, scenario.expectations ]
    assert_equal 1, scenario.position
    assert scenario.enabled
    assert_equal [ "Hand written", false, 0 ], evaluation.scenarios.find_by!(key: "orders_1").values_at(:prompt, :enabled, :position)
    exploration.reload
    assert_equal [ "accepted", key ], exploration.candidates.first.values_at("state", "scenario_key")
    assert_equal [ "proposed", nil ], exploration.candidates.second.values_at("state", "scenario_key")
    assert_equal evaluation.id, exploration.evaluation_id
    assert_equal "review", exploration.status
  end

  test "accepting twice updates the same scenarios, and a second exploration leaves the first one's alone" do
    evaluation = @project.evaluation
    hand_written = evaluation.scenarios.create!(key: "faq_1", prompt: "What are your hours?", group: "FAQ", position: 0)
    first = explore(candidate("Where is order A-17?", tools: [ "lookup_order" ], rubric: "Gives the status."))
    first.accept!([ 1 ])
    first_scenario = evaluation.scenarios.find_by!(key: "x#{first.id}_1")
    first_scenario.update!(enabled: false)

    first.update_candidate!(1, "rubric" => "Gives the status and the carrier.")
    again = first.accept!([ 1 ])
    assert_equal [ [], [ "x#{first.id}_1" ] ], again.values_at(:added, :updated)
    assert_equal 2, evaluation.scenarios.count
    assert_equal [ "Gives the status and the carrier.", false ], first_scenario.reload.values_at(:notes, :enabled)

    second = explore(candidate("Where is order A-17?", tools: [ "lookup_order" ], rubric: "Something else."))
    second.accept!([ 1 ])

    assert_equal 3, evaluation.scenarios.count
    assert_equal [ "Gives the status and the carrier.", false ], first_scenario.reload.values_at(:notes, :enabled)
    assert_equal [ "What are your hours?", true, 0 ], hand_written.reload.values_at(:prompt, :enabled, :position)
    assert_equal "Something else.", evaluation.scenarios.find_by!(key: "x#{second.id}_1").notes
  end

  test "accept refuses a key a scenario from outside the exploration holds, and writes nothing" do
    exploration = explore(candidate("Where is order A-17?"), candidate("Which orders shipped late?"))
    squatter = @project.evaluation.scenarios.create!(key: "x#{exploration.id}_2", prompt: "Hand written", position: 0)

    error = assert_raises(ActionAgent::Exploration::AcceptRefused) { exploration.accept!([ 1, 2 ]) }

    assert_equal [ 2 ], error.problems.keys
    assert_match(/already has a scenario x#{exploration.id}_2/, error.problems[2])
    assert_equal [ squatter.key ], @project.evaluation.scenarios.pluck(:key)
    assert_equal %w[proposed proposed], exploration.reload.candidates.map { |row| row["state"] }
  end

  test "accept refuses a rejected candidate until it is reconsidered" do
    exploration = explore(candidate("Where is order A-17?"))
    exploration.update_candidate!(1, "state" => "rejected")

    error = assert_raises(ActionAgent::Exploration::AcceptRefused) { exploration.accept!([ 1 ]) }
    assert_equal({ 1 => "it was rejected: reconsider it first" }, error.problems)
    assert_equal 0, @project.evaluation.scenarios.count

    exploration.update_candidate!(1, "state" => "proposed")
    assert_equal [ "x#{exploration.id}_1" ], exploration.accept!([ 1 ])[:added]
  end

  test "accept refuses a pattern the suite editor would split, and an unknown or missing id" do
    exploration = explore(candidate("Where is order A-17?", contains: [ "shipped, on time" ]), candidate("Hello"))

    error = assert_raises(ActionAgent::Exploration::AcceptRefused) { exploration.accept!([ 1, 2 ]) }
    assert_match(/contains “shipped, on time” has a comma/, error.problems[1])
    assert_equal 0, @project.evaluation.scenarios.count

    assert_raises(ActionAgent::Exploration::AcceptRefused) { exploration.accept!([ 7 ]) }
    assert_raises(ActionAgent::Exploration::AcceptRefused) { exploration.accept!([]) }

    merged = exploration.accept!([ 1 ], edits: { "1" => { "contains" => [ "shipped on time" ] } })
    assert_equal [ "x#{exploration.id}_1" ], merged[:added]
    assert_equal({ "contains" => [ "shipped on time" ] }, @project.evaluation.scenarios.sole.expectations)
  end

  test "an accepted scenario comes back unchanged through a Save in the suite editor" do
    exploration = explore(candidate("**Which** orders shipped late?", group: "Orders", tools: [ "find_orders" ],
      rubric: "Lists each late order;\nsays so when there are none | politely", contains: [ "late" ]))
    exploration.accept!([ 1 ])
    scenario = @project.evaluation.scenarios.sole

    entry = scenario.slice(:key, :prompt, :group, :notes, :expectations).stringify_keys
    parsed = ActiveAgent::Evals::ScenarioParser.parse("# #{entry['group']}\n#{ActionAgent::Exploration.suite_editor_line(entry)}").sole

    assert_equal entry.values_at("key", "prompt", "group", "notes", "expectations"),
      parsed.values_at("key", "prompt", "group", "notes", "expectations")
    assert_equal "Which orders shipped late?", scenario.prompt
  end

  test "suite_editor_line writes the line the suite editor's Save writes" do
    SUITE_EDITOR_LINES.each do |example|
      assert_equal example["line"], ActionAgent::Exploration.suite_editor_line(example["entry"])
    end
  end

  test "the project's first accept creates its evaluation when it has none, on the target agent" do
    @project.evaluation.destroy!
    exploration = explore(candidate("Where is order A-17?"))

    merged = exploration.accept!([ 1 ])

    evaluation = merged[:evaluation]
    assert_equal [ @project.target_agent_id, evaluation.id ], [ evaluation.agent_id, @project.reload.evaluation_id ]
    assert_equal [ "x#{exploration.id}_1" ], evaluation.scenarios.pluck(:key)
  end

  test "stop moves a running exploration to review with its candidates, and nothing else" do
    exploration = explore(candidate("Where is order A-17?"))
    exploration.update!(status: "running")

    assert exploration.stop!
    assert_equal [ "review", "stopped", 1 ], [ exploration.status, exploration.stop_reason, exploration.candidates.size ]
    assert exploration.finished_at
    assert_not exploration.stop!
  end

  test "candidates for the project's own evaluation are filed under the project and scrubbed of its secrets" do
    exploration = ActionAgent::Exploration.build_for(evaluation: @project.evaluation, source: "external", status: "review")
    exploration.save_with_candidates!([ candidate("Pay with #{SECRET}", tools: [ "lookup_order", "refund_order" ]) ])

    assert_equal [ @project.id, @project.evaluation.id, "/" ], [ exploration.project_id, exploration.evaluation_id, exploration.start_url ]
    row = exploration.reload.candidates.sole
    assert_equal [ "Pay with [REDACTED]", "needs_tool", [ "refund_order" ] ], row.values_at("prompt", "verdict", "missing_tools")
  end

  test "candidates for another evaluation of the project's agent stay on it, scrubbed of the project's secrets" do
    second = @project.target_agent.evaluations.create!(name: "Second suite", judge_kind: "rules",
      criteria: [ { "key" => "answered", "type" => "response_present", "config" => {} } ])
    exploration = ActionAgent::Exploration.build_for(evaluation: second, source: "external", status: "review")
    exploration.save_with_candidates!([ candidate("Pay with #{SECRET} and #{RUNTIME_TOKEN}", tools: [ "find_orders" ]) ])

    assert_equal [ nil, second.id, @project ], [ exploration.project_id, exploration.evaluation_id, exploration.app_project ]
    row = exploration.reload.candidates.sole
    assert_equal [ "Pay with [REDACTED] and [REDACTED]", "answerable" ], row.values_at("prompt", "verdict")
    assert_equal second, exploration.target_evaluation

    @project.current_sandbox_session.update!(status: :expired)
    assert_nil exploration.tool_roster, "the project's stopped sandbox leaves the app's tools unread"
  end

  test "an evaluation of another owner's agent is never matched to a project" do
    ActionAgent::Project.where(id: @project.id).update_all(account_id: 99)

    assert_nil ActionAgent::Project.for_evaluation(@project.evaluation)
    assert_nil ActionAgent::Project.for_evaluation(nil)
  end

  test "a JSON column left unset reads as empty" do
    exploration = ActionAgent::Exploration.build_for(project: @project, source: "external")
    exploration.save!
    exploration.update_columns(candidates: nil, budget: nil, usage: nil)

    exploration.reload
    assert_equal [ [], {}, {} ], [ exploration.candidates, exploration.budget, exploration.usage ]
    assert_equal "/", exploration.start_url
  end

  test "deleting the project deletes its explorations" do
    explore(candidate("Where is order A-17?"))

    @project.discard!

    assert_equal 0, ActionAgent::Exploration.count
  end
end
