# frozen_string_literal: true

require "test_helper"

# The MCP facade's two write tools: evaluations_create and scenarios_merge,
# which let a coding harness seed an evaluation it then runs, without ever
# removing or disabling a scenario it was not given.
class McpEvaluationAuthoringTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  WRITE_TOOLS = %w[evaluations_create scenarios_merge].freeze
  PASTE = "# Orders\nWhere is order ABC-123? | tools: lookup_order\nWhich orders shipped late?"

  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::ApiKey.delete_all
    @key = ActionAgent::ApiKey.create!(name: "Harness")
    @agent = ActionAgent::Agent.create!(name: "Support", slug: "support", provider: "mock", model: "mock-model",
                                        instructions: "Answer from data.", status: :active)
    @asked = []
  end

  def teardown
    ActionAgent.mcp_dashboard_tools = nil
    ActionAgent.execution_enabled = true
    ActionAgent.usage_recorder = nil
    ActionAgent.permission_checker = nil
    ActionAgent.scenario_evaluation_adapter_resolver = nil
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.multi_tenant = false
  end

  def rpc(method, params = {}, key: @key)
    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{key.token}" }
    JSON.parse(response.body)
  end

  def call_tool(name, arguments = {}, key: @key)
    rpc("tools/call", { name: name, arguments: arguments }, key: key)
  end

  def structured(body)
    assert_nil body["error"], body.inspect
    assert_nil body.dig("result", "isError"), body.inspect
    body.dig("result", "structuredContent")
  end

  def tool_error(body)
    assert_equal true, body.dig("result", "isError"), body.inspect
    body.dig("result", "content", 0, "text")
  end

  test "tools/list offers both write tools only while the dashboard tools are on" do
    tools = rpc("tools/list").dig("result", "tools").index_by { |tool| tool["name"] }
    assert_empty WRITE_TOOLS - tools.keys
    assert_equal %w[agent name], tools["evaluations_create"].dig("inputSchema", "required")
    assert_equal %w[evaluation_id], tools["scenarios_merge"].dig("inputSchema", "required")
    instructions = rpc("initialize").dig("result", "instructions")
    WRITE_TOOLS.each { |name| assert_includes instructions, name }

    ActionAgent.mcp_dashboard_tools = false

    names = rpc("tools/list").dig("result", "tools").map { |tool| tool["name"] }
    assert_empty WRITE_TOOLS & names
    assert_equal(-32602, call_tool("evaluations_create", { agent: "support", name: "Off" }).dig("error", "code"))
    assert_equal 0, ActionAgent::Evaluation.count
  end

  test "evaluations_create builds a scenario suite with default criteria and runs nothing" do
    ActionAgent.execution_enabled = false
    recorded = []
    ActionAgent.usage_recorder = ->(_owner, kind) { recorded << kind }

    result = nil
    assert_no_enqueued_jobs do
      result = structured(call_tool("evaluations_create", {
        agent: "support", name: "Order questions", compare_models: [ "mock/alpha", "mock/beta" ], scenarios_text: PASTE
      }))
    end

    evaluation = ActionAgent::Evaluation.find(result.dig("evaluation", "id"))
    assert_equal %w[orders_1 orders_2], result["added"]
    assert_equal 2, result.dig("evaluation", "scenario_count")
    assert_equal true, result.dig("evaluation", "scenario_suite")
    assert_equal @agent, evaluation.agent
    assert_equal ActionAgent::Api::EvaluationsController::DEFAULT_CRITERIA, evaluation.criteria
    assert_equal %w[mock/alpha mock/beta], evaluation.compare_models
    assert_equal [ "lookup_order" ], evaluation.scenarios.find_by!(key: "orders_1").expected_tools
    assert_empty evaluation.evaluation_runs
    assert_empty recorded
  end

  test "evaluations_create takes scenarios as objects, a key prefix, explicit criteria and a judge" do
    result = structured(call_tool("evaluations_create", {
      agent: @agent.id.to_s, name: "Refunds", judge_kind: "llm", judge_model: "mock/judge",
      criteria: [ { type: "contains", config: { "patterns" => [ "refund" ] } } ],
      scenarios: [ { prompt: "Can I get a refund?", group: "Refunds", notes: "Says the 30-day window." },
                   { prompt: "Refund my order", key: "refund_order", contains: [ "refund" ] } ],
      key_prefix: "harness"
    }))

    evaluation = ActionAgent::Evaluation.find(result.dig("evaluation", "id"))
    assert_equal %w[harness_refunds_1 refund_order], result["added"]
    assert_equal "llm", evaluation.judge_kind
    assert_equal "mock/judge", evaluation.judge_model
    assert_equal [ { "key" => "contains", "type" => "contains", "config" => { "patterns" => [ "refund" ] } } ], evaluation.criteria
    assert_equal "Says the 30-day window.", evaluation.scenarios.find_by!(key: "harness_refunds_1").notes
  end

  test "evaluations_create without scenarios creates a sampling evaluation" do
    result = structured(call_tool("evaluations_create", { agent: "support", name: "Recorded answers" }))

    assert_equal false, result.dig("evaluation", "scenario_suite")
    assert_empty result["added"]
  end

  test "through evaluations_create another owner's agent reads as a nonexistent one" do
    ActionAgent.user_class = "User"
    me = User.create!(email: "me-#{SecureRandom.hex(3)}@example.com", name: "Me", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    @agent.update_columns(user_id: stranger.id)
    @key.update_columns(user_id: me.id)

    theirs = tool_error(call_tool("evaluations_create", { agent: "support", name: "Mine now", scenarios_text: PASTE }))
    nothing = tool_error(call_tool("evaluations_create", { agent: "nobody", name: "Mine now", scenarios_text: PASTE }))
    by_id = tool_error(call_tool("evaluations_create", { agent: @agent.id.to_s, name: "Mine now" }))

    assert_equal nothing.sub("nobody", "AGENT"), theirs.sub("support", "AGENT")
    assert_match(/No agent #{@agent.id} was found/, by_id)
    assert_equal 0, ActionAgent::Evaluation.count
  end

  test "a duplicate name, invalid criteria or unparseable scenarios return an error and write nothing" do
    existing = @agent.evaluations.create!(name: "Order questions", criteria: [ { "key" => "present", "type" => "response_present" } ])

    duplicate = tool_error(call_tool("evaluations_create", { agent: "support", name: "Order questions", scenarios_text: PASTE }))
    unknown = tool_error(call_tool("evaluations_create", {
      agent: "support", name: "Other", criteria: [ { type: "vibes" } ], scenarios_text: PASTE
    }))
    malformed = tool_error(call_tool("evaluations_create", { agent: "support", name: "Other", criteria: "response_present" }))
    unparseable = tool_error(call_tool("evaluations_create", { agent: "support", name: "Other", scenarios_text: "groups:\n  - invalid" }))
    long_name = tool_error(call_tool("evaluations_create", { agent: "support", name: "x" * 256 }))

    assert_match(/Name has already been taken/, duplicate)
    assert_match(/unknown criterion type vibes/, unknown)
    assert_match(/criteria must be an array/, malformed)
    assert_match(/scenarios array/, unparseable)
    assert_match(/longer than 255/, long_name)
    assert_equal [ existing.id ], ActionAgent::Evaluation.pluck(:id)
    assert_equal 0, ActionAgent::EvaluationScenario.count
  end

  test "a missing agent, name or evaluation id is a JSON-RPC invalid-params error" do
    assert_equal(-32602, call_tool("evaluations_create", { name: "No agent" }).dig("error", "code"))
    assert_equal(-32602, call_tool("evaluations_create", { agent: "support" }).dig("error", "code"))
    assert_equal(-32602, call_tool("scenarios_merge", { scenarios_text: PASTE }).dig("error", "code"))
    assert_equal 0, ActionAgent::Evaluation.count
  end

  test "scenarios_merge adds the same keyless paste twice under distinct keys and updates nothing" do
    suite = create_suite

    first = structured(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE }))
    second = structured(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE }))

    assert_equal [ %w[orders_2 orders_3], [], [] ], first.values_at("added", "updated", "unchanged")
    assert_equal [ %w[orders_4 orders_5], [], [] ], second.values_at("added", "updated", "unchanged")
    assert_equal 5, second["scenario_count"]
    assert_equal %w[orders_1 orders_2 orders_3 orders_4 orders_5], suite.scenarios.ordered.map(&:key)
  end

  test "scenarios_merge never touches a scenario it was not given, results included" do
    suite = create_suite
    kept = suite.scenarios.sole
    kept.update!(enabled: false)
    run = suite.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    result = run.scenario_results.create!(scenario: kept, provider: "mock", model: "mock/alpha", status: :passed)
    before = kept.reload.attributes

    structured(call_tool("scenarios_merge", {
      evaluation_id: suite.id, scenarios: [ { prompt: "Can I get a refund?", group: "Refunds" } ]
    }))

    assert_equal before, kept.reload.attributes
    assert ActionAgent::EvaluationScenarioResult.exists?(result.id)
  end

  test "scenarios_merge updates a given key in place and keeps its enabled flag and position" do
    suite = create_suite
    scenario = suite.scenarios.sole
    scenario.update!(enabled: false, position: 4)

    merged = structured(call_tool("scenarios_merge", {
      evaluation_id: suite.id,
      scenarios: [ { key: "orders_1", prompt: "Where is order XYZ-9?", group: "Orders", notes: "Says it shipped." },
                   { key: "refunds_1", prompt: "Can I get a refund?", group: "Refunds" } ]
    }))
    again = structured(call_tool("scenarios_merge", {
      evaluation_id: suite.id, scenarios: [ { key: "orders_1", prompt: "Where is order XYZ-9?", group: "Orders", notes: "Says it shipped." } ]
    }))

    assert_equal [ [ "refunds_1" ], [ "orders_1" ], [] ], merged.values_at("added", "updated", "unchanged")
    assert_equal [ [], [], [ "orders_1" ] ], again.values_at("added", "updated", "unchanged")
    scenario.reload
    assert_equal [ "Where is order XYZ-9?", "Says it shipped.", false, 4 ], [ scenario.prompt, scenario.notes, scenario.enabled, scenario.position ]
    assert_equal 5, suite.scenarios.find_by!(key: "refunds_1").position, "a new key is appended after the last position"
  end

  test "scenarios_merge namespaces generated keys with key_prefix" do
    suite = create_suite

    merged = structured(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE, key_prefix: "batch2" }))

    assert_equal %w[batch2_orders_1 batch2_orders_2], merged["added"]
  end

  test "scenarios_merge with nothing to merge is a tool error" do
    suite = create_suite

    assert_match(/Give the scenarios/, tool_error(call_tool("scenarios_merge", { evaluation_id: suite.id })))
    assert_match(/No scenarios matched/, tool_error(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios: [ { notes: "no prompt" } ] })))
    assert_match(/must be an array/, tool_error(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios: { prompt: "One" } })))
    assert_equal 1, suite.scenarios.count
  end

  test "a scenario whose key, group, prompt or notes is too long for its column is refused and nothing is written" do
    suite = create_suite
    oversized = {
      key: { prompt: "One", key: "k" * 201 },
      group: { prompt: "One", group: "g" * 201 },
      prompt: { prompt: "p" * 65_536 },
      notes: { prompt: "One", notes: "n" * 65_536 }
    }

    errors = oversized.transform_values do |scenario|
      tool_error(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios: [ { prompt: "Fine" }, scenario ] }))
    end
    created = tool_error(call_tool("evaluations_create", { agent: "support", name: "Long", scenarios: [ oversized[:group] ] }))

    assert_match(/key is longer than 200 characters/, errors[:key])
    assert_match(/group is longer than 200 characters/, errors[:group])
    assert_match(/prompt is larger than 65535 bytes/, errors[:prompt])
    assert_match(/notes is larger than 65535 bytes/, errors[:notes])
    assert_match(/group is longer than 200 characters/, created)
    assert_equal [ "orders_1" ], suite.scenarios.pluck(:key)
    assert_equal [ suite.id ], ActionAgent::Evaluation.pluck(:id)
  end

  test "a call whose scenarios total more than 2 MiB is refused and writes nothing" do
    suite = create_suite
    batch = Array.new(40) { |index| { prompt: "Question #{index}? #{'p' * 30_000}", notes: "n" * 30_000 } }

    merged = tool_error(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios: batch }))
    created = tool_error(call_tool("evaluations_create", { agent: "support", name: "Large", scenarios: batch }))
    structured(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios: batch.first(30) }))

    assert_match(/may total 2 MiB and these total 2\.3 MiB/, merged)
    assert_match(/may total 2 MiB/, created)
    assert_equal 31, suite.scenarios.count
    assert_equal [ suite.id ], ActionAgent::Evaluation.pluck(:id)
  end

  test "a judge model longer than 200 characters is refused" do
    error = tool_error(call_tool("evaluations_create", { agent: "support", name: "Judged", judge_kind: "llm", judge_model: "m" * 201 }))

    assert_match(/judge_model is longer than 200 characters/, error)
    assert_equal 0, ActionAgent::Evaluation.count
  end

  test "through scenarios_merge another owner's evaluation reads as a nonexistent one" do
    ActionAgent.user_class = "User"
    me = User.create!(email: "me-#{SecureRandom.hex(3)}@example.com", name: "Me", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    suite = create_suite
    @agent.update_columns(user_id: stranger.id)
    @key.update_columns(user_id: me.id)
    missing = ActionAgent::Evaluation.maximum(:id).to_i + 100

    theirs = tool_error(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE }))
    nothing = tool_error(call_tool("scenarios_merge", { evaluation_id: missing, scenarios_text: PASTE }))

    assert_equal nothing.sub(missing.to_s, "ID"), theirs.sub(suite.id.to_s, "ID")
    assert_equal 1, suite.scenarios.count
  end

  test "an observed agent's suite is refused unless a host adapter replays it" do
    suite = create_suite
    @agent.update!(status: :observed)

    created = tool_error(call_tool("evaluations_create", { agent: "support", name: "Observed", scenarios_text: PASTE }))
    merged = tool_error(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE }))

    assert_match(/read-only/, created)
    assert_match(/read-only/, merged)
    assert_equal [ suite.id ], ActionAgent::Evaluation.pluck(:id)
    assert_equal 1, suite.scenarios.count

    structured(call_tool("evaluations_create", { agent: "support", name: "Recorded answers" }))

    persisted = []
    ActionAgent.scenario_evaluation_adapter_resolver = ->(evaluation) { persisted << evaluation.persisted?; ->(**) { } }
    structured(call_tool("evaluations_create", { agent: "support", name: "Adapted", scenarios_text: PASTE }))
    structured(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE }))
    assert_equal 3, suite.scenarios.count
    assert_equal [ true, true ], persisted, "the resolver is handed a saved evaluation, as its contract says"
  end

  test "the checker is asked about replace_scenarios as the key's user, with the evaluation" do
    ActionAgent.user_class = "User"
    creator = User.create!(email: "creator-#{SecureRandom.hex(3)}@example.com", name: "Creator", age: 30)
    @agent.update_columns(user_id: creator.id)
    @key.update_columns(user_id: creator.id)
    suite = create_suite
    ActionAgent.permission_checker = ->(*args) { @asked << args; true }

    structured(call_tool("evaluations_create", { agent: "support", name: "Refunds", scenarios_text: PASTE }))
    structured(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE }))

    (create_user, create_action, create_subject), (merge_user, merge_action, merge_subject) = @asked
    assert_equal [ :replace_scenarios, :replace_scenarios ], [ create_action, merge_action ]
    assert_equal [ creator, creator ], [ create_user, merge_user ]
    assert_kind_of ActionAgent::Evaluation, create_subject
    assert_equal [ "Refunds", 2 ], [ create_subject.name, create_subject.scenarios.size ]
    assert_equal suite, merge_subject
  end

  test "multi-tenant: a checker that denies, answers nil or raises makes both tools write nothing" do
    _account, member = multi_tenant_key
    suite = create_suite

    [ ->(*) { false }, ->(*) { nil }, ->(*) { raise "policy service down" } ].each do |checker|
      ActionAgent.permission_checker = checker

      created = call_tool("evaluations_create", { agent: "support", name: "Refunds", scenarios_text: PASTE })
      merged = call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE })

      [ created, merged ].each do |body|
        assert_equal(-32003, body.dig("error", "code"), body.inspect)
        assert_match(/replace_scenarios/, body.dig("error", "message"))
      end
    end
    assert_equal [ suite.id ], ActionAgent::Evaluation.pluck(:id)
    assert_equal 1, suite.scenarios.count

    ActionAgent.permission_checker = ->(*args) { @asked << args; true }
    structured(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE }))
    assert_equal member, @asked.sole.first
  end

  test "multi-tenant: with a checker set, a key that records no user is denied without asking it" do
    multi_tenant_key
    @key.update_columns(user_id: nil)
    suite = create_suite
    ActionAgent.permission_checker = ->(*args) { @asked << args; true }

    created = call_tool("evaluations_create", { agent: "support", name: "Refunds", scenarios_text: PASTE })
    merged = call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE })

    assert_equal [ -32003, -32003 ], [ created.dig("error", "code"), merged.dig("error", "code") ]
    assert_empty @asked
    assert_equal 1, ActionAgent::Evaluation.count
    assert_equal 1, suite.scenarios.count
  end

  test "multi-tenant: with no checker set, a key that records no user may write" do
    multi_tenant_key
    @key.update_columns(user_id: nil)
    suite = create_suite

    structured(call_tool("evaluations_create", { agent: "support", name: "Refunds", scenarios_text: PASTE }))
    structured(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios_text: PASTE }))

    assert_equal 2, ActionAgent::Evaluation.count
    assert_equal 3, suite.scenarios.count
  end

  test "a create that would pass the evaluation or scenario limit is refused whole" do
    now = Time.current
    ActionAgent::Evaluation.insert_all(
      Array.new(ActionAgent::EvaluationReportImport::MAX_EVALUATIONS_PER_AGENT) do |index|
        { agent_id: @agent.id, name: "Suite #{index}", judge_kind: "rules", criteria: [], config: {}, sample_size: 20,
          created_at: now, updated_at: now }
      end
    )

    at_limit = tool_error(call_tool("evaluations_create", { agent: "support", name: "One more", scenarios_text: PASTE }))

    assert_match(/Evaluation limit reached \(100 for this agent\)/, at_limit)
    assert_nil ActionAgent::Evaluation.find_by(name: "One more")
    assert_equal 0, ActionAgent::EvaluationScenario.count

    ActionAgent::Evaluation.delete_all
    too_many = (ActionAgent::EvaluationReportImport::MAX_SCENARIOS_PER_EVALUATION + 1).times.map { |index| "Question #{index}?" }.join("\n")
    over = tool_error(call_tool("evaluations_create", { agent: "support", name: "Huge", scenarios_text: too_many }))

    assert_match(/Scenario limit reached \(2000 per evaluation\): this call gives 2001/, over)
    assert_equal 0, ActionAgent::Evaluation.count
  end

  test "a merge that would pass the scenario limit is refused whole" do
    suite = create_suite
    now = Time.current
    ActionAgent::EvaluationScenario.insert_all(
      Array.new(ActionAgent::EvaluationReportImport::MAX_SCENARIOS_PER_EVALUATION - 2) do |index|
        { evaluation_id: suite.id, key: "seeded_#{index}", prompt: "Seeded #{index}?", position: index + 1,
          enabled: true, created_at: now, updated_at: now }
      end
    )

    over = tool_error(call_tool("scenarios_merge", {
      evaluation_id: suite.id,
      scenarios: [ { key: "orders_1", prompt: "Changed?" }, { prompt: "One" }, { prompt: "Two" } ]
    }))

    assert_match(/Scenario limit reached \(2000 per evaluation\): the evaluation holds 1999 and this merge adds 2/, over)
    assert_equal 1999, suite.scenarios.count
    assert_equal "Where is order ABC-123?", suite.scenarios.find_by!(key: "orders_1").prompt

    structured(call_tool("scenarios_merge", { evaluation_id: suite.id, scenarios: [ { prompt: "One" } ] }))
    assert_equal 2000, suite.scenarios.count
  end

  private

  def create_suite
    evaluation = @agent.evaluations.new(name: "Support lookups", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "orders_1", prompt: "Where is order ABC-123?", group: "Orders",
                               expectations: { "contains" => [ "shipped" ] })
    evaluation.save!
    evaluation
  end

  # A multi-tenant install whose account is a User (the dummy app has no
  # Account), with the key owned by the account and created by a member.
  # Agents are owned per user before per account, so the agent's user_id
  # names the account too.
  def multi_tenant_key
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    ActionAgent.multi_tenant = true
    account = User.create!(email: "account-#{SecureRandom.hex(3)}@example.com", name: "Account", age: 30)
    member = User.create!(email: "member-#{SecureRandom.hex(3)}@example.com", name: "Member", age: 30)
    @agent.update_columns(account_id: account.id, user_id: account.id)
    @key.update_columns(account_id: account.id, user_id: member.id)
    [ account, member ]
  end
end
