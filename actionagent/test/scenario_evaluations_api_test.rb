# frozen_string_literal: true

require "test_helper"

# The scenario-suite half of the evaluations API: creating an evaluation
# from pasted messages, managing its scenarios, running a selection under
# chosen models, and reading a run's per-scenario results.
class ActionAgentScenarioEvaluationsApiTest < ActionDispatch::IntegrationTest
  SUPPORT_SUITE = File.expand_path("../../test/evals/fixtures/support_suite.yml", __dir__)

  test "a grouped YAML suite imports its keys and expectations and excludes production questions by default" do
    agent = create_agent

    post "/activeagents/api/evaluations", params: {
      evaluation: { agent_id: agent.id, name: "Support catalog", scenarios_text: File.read(SUPPORT_SUITE), run: false }
    }, as: :json

    assert_response :created
    evaluation = agent.evaluations.last
    assert_equal %w[order_lookup help_cancel], evaluation.scenarios.ordered.map(&:key)
    assert_equal %w[orders help], evaluation.scenarios.ordered.map(&:group)
    assert_equal({ "tools" => [ "lookup_order" ], "contains" => [ "ABC-123" ], "not_contains" => [ "password" ] },
                 evaluation.scenarios.find_by!(key: "order_lookup").expectations)
    assert_equal "Use the synthetic test order.", evaluation.scenarios.find_by!(key: "order_lookup").notes
    assert_nil evaluation.latest_run
  end

  test "production questions can be explicitly included when creating or replacing a suite" do
    agent = create_agent

    post "/activeagents/api/evaluations", params: {
      evaluation: { agent_id: agent.id, name: "Support catalog", scenarios_text: File.read(SUPPORT_SUITE),
                    include_production_only: true, run: false }
    }, as: :json

    assert_response :created
    evaluation = agent.evaluations.last
    assert_equal %w[order_lookup live_volume help_cancel], evaluation.scenarios.ordered.map(&:key)
    assert_equal [ "count_orders" ], evaluation.scenarios.find_by!(key: "live_volume").expected_tools

    put "/activeagents/api/evaluations/#{evaluation.id}/scenarios",
        params: { scenarios_text: File.read(SUPPORT_SUITE), include_production_only: "false" }, as: :json
    assert_response :success
    assert_equal %w[order_lookup help_cancel], evaluation.scenarios.ordered.map(&:key)

    put "/activeagents/api/evaluations/#{evaluation.id}/scenarios",
        params: { scenarios_text: File.read(SUPPORT_SUITE), include_production_only: "true" }, as: :json
    assert_response :success
    assert_equal %w[order_lookup live_volume help_cancel], evaluation.scenarios.ordered.map(&:key)
  end

  test "invalid YAML and fully excluded suites return an import error without creating a sampling evaluation" do
    agent = create_agent
    production = { suite: "live", groups: [ { key: "orders", scenarios: [
      { key: "live_1", prompt: "Count orders today.", production_only: true }
    ] } ] }.to_json

    [ "suite: support\ngroups: [", production ].each do |text|
      assert_no_difference -> { agent.evaluations.count } do
        post "/activeagents/api/evaluations", params: {
          evaluation: { agent_id: agent.id, name: "Support catalog", scenarios_text: text, run: false }
        }, as: :json
      end
      assert_response :unprocessable_entity
      assert JSON.parse(response.body)["errors"].present?
    end
  end

  def setup
    ActionAgent::Agent.delete_all
  end

  def teardown
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
    ActionAgent.execution_enabled = true
  end

  def create_agent(**attributes)
    ActionAgent::Agent.create!({ name: "Assistant", provider: "mock", model: "mock-model", instructions: "Answer from data." }.merge(attributes))
  end

  def create_suite(agent, prompt: "First")
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "a_1", prompt: prompt)
    evaluation.save!
    evaluation
  end

  CATALOG = <<~TEXT
    # Find records
    1. `Which gynecologists in Charlotte have scheduling enabled?` — 314 locally
    2. `Show me all providers with no license on file` | tools: find_records
    # Blame
    3. Who changed the biography for Dr. AbdelRazek?
  TEXT

  test "pasting a list of messages creates a scenario suite and queues its first run" do
    agent = create_agent

    post "/activeagents/api/evaluations", params: {
      evaluation: { agent_id: agent.id, name: "Question catalog", scenarios_text: CATALOG, compare_models: "mock/alpha, mock/beta" }
    }, as: :json

    assert_response :created
    body = JSON.parse(response.body)["evaluation"]
    assert body["scenario_suite"]
    assert_equal 3, body["scenario_count"]
    assert_equal [ "Blame", "Find records" ], body["scenario_groups"]
    assert_equal %w[mock/alpha mock/beta], body["compare_models"]
    assert_equal "pending", body.dig("latest_run", "status")

    evaluation = ActionAgent::Evaluation.find(body["id"])
    assert_equal %w[find_records_1 find_records_2 blame_1], evaluation.scenarios.ordered.map(&:key)
    assert_equal [ "find_records" ], evaluation.scenarios.find_by!(key: "find_records_2").expected_tools
    assert_enqueued_jobs 1, only: ActionAgent::EvaluationRunJob
  end

  # An empty criteria list is indistinguishable from an omitted one through
  # the API, so the suite gets the rule-based defaults; only the model layer
  # accepts a suite scored on its scenarios' expectations alone.
  test "a suite posted with an empty criteria list gets the default rule criteria and no run when told not to" do
    agent = create_agent

    post "/activeagents/api/evaluations", params: {
      evaluation: { agent_id: agent.id, name: "Bare suite", scenarios: [ { prompt: "Hello", group: "Smoke" } ], criteria: [], run: false }
    }, as: :json

    assert_response :created
    evaluation = ActionAgent::Evaluation.find(JSON.parse(response.body).dig("evaluation", "id"))
    assert_equal 1, evaluation.scenarios.count
    assert_equal %w[response_present response_length latency token_budget], evaluation.criteria.map { |criterion| criterion["key"] }
    assert_nil evaluation.latest_run
  end

  test "running a suite is agent execution: refused when the dashboard's execution is off" do
    evaluation = create_suite(create_agent)
    ActionAgent.execution_enabled = false

    post "/activeagents/api/evaluations/#{evaluation.id}/run", params: { models: [ "mock/alpha" ] }, as: :json

    assert_response :forbidden
    assert_nil evaluation.latest_run
    assert_no_enqueued_jobs only: ActionAgent::EvaluationRunJob
  end

  test "creating a suite that runs is subject to the host's execution quota; creating one that does not run is not" do
    agent = create_agent
    ActionAgent.quota_checker = ->(_owner, kind) { "Out of runs" if kind == :execution }

    post "/activeagents/api/evaluations", params: { evaluation: { agent_id: agent.id, name: "Catalog", scenarios_text: "First" } }, as: :json
    assert_response :payment_required
    assert_equal 0, agent.evaluations.count

    post "/activeagents/api/evaluations", params: { evaluation: { agent_id: agent.id, name: "Catalog", scenarios_text: "First", run: false } }, as: :json
    assert_response :created
  end

  test "a generation-sampling evaluation is not gated: it scores recorded data rather than executing the agent" do
    agent = create_agent
    ActionAgent.execution_enabled = false

    post "/activeagents/api/evaluations", params: { evaluation: { agent_id: agent.id, name: "Sampled" } }, as: :json

    assert_response :created
  end

  test "an observed agent's suite cannot be run" do
    evaluation = create_suite(create_agent(status: :observed))

    post "/activeagents/api/evaluations/#{evaluation.id}/run", as: :json

    assert_response :unprocessable_entity
    assert_match(/read-only/, JSON.parse(response.body)["error"])
  end

  test "an observed agent evaluation runs only through its explicitly configured host adapter" do
    evaluation = create_suite(create_agent(status: :observed))
    previous = ActionAgent.scenario_evaluation_adapter_resolver
    ActionAgent.scenario_evaluation_adapter_resolver = lambda do |candidate|
      next unless candidate.id == evaluation.id

      lambda do |scenarios:, models:, on_result:, **|
        ActiveAgent::Evals::Runner.new(
          scenarios: scenarios, models: models, on_result: on_result,
          replay: ->(*) { ActiveAgent::Evals::Replay.new(answer: "The host answered.", metadata: { "trace_id" => "host-trace" }) },
          metadata: { "run_id" => "host-evaluation" }
        ).call
      end
    end

    assert_no_difference "ActionAgent::AgentRun.count" do
      perform_enqueued_jobs do
        post "/activeagents/api/evaluations/#{evaluation.id}/run", as: :json
      end
    end
    assert_response :success
    run = evaluation.evaluation_runs.recent.first
    assert_equal "complete", run.status
    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}"
    assert_response :success
    assert_equal "host-trace", JSON.parse(response.body).dig("run", "results", 0, "metadata", "trace_id")
    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}/report"
    assert_response :success
    assert_includes response.body, "The host answered."
  ensure
    ActionAgent.scenario_evaluation_adapter_resolver = previous
  end

  test "a run can be narrowed to a group and to models, and its results are readable" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    ActiveAgent::Evals::ScenarioParser.parse(CATALOG).each do |attrs|
      evaluation.scenarios.build(attrs.slice("key", "prompt", "group", "notes", "expectations", "position"))
    end
    evaluation.save!

    perform_enqueued_jobs do
      post "/activeagents/api/evaluations/#{evaluation.id}/run", params: { group: "Find records", models: [ "mock/alpha", "mock/beta" ] }, as: :json
    end

    assert_response :success
    run_id = JSON.parse(response.body).dig("run", "id")

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run_id}"

    assert_response :success
    run = JSON.parse(response.body)["run"]
    assert_equal "complete", run["status"]
    assert_equal %w[mock/alpha mock/beta], run["models"]
    assert_equal "Find records", run.dig("selection", "group")
    assert_equal 4, run["results"].size
    assert_equal %w[find_records_1 find_records_1 find_records_2 find_records_2], run["results"].map { |r| r["scenario_key"] }
    tool_miss = run["results"].find { |r| r["scenario_key"] == "find_records_2" }
    assert_equal "expected_tool_not_called", tool_miss["fault"]
    assert tool_miss["recommendation"].present?
    assert run["scores"]["_verdict"].present?
  end

  test "scenarios can be listed, replaced from a new paste, edited and deleted" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "a_1", group: "A", prompt: "First")
    evaluation.save!

    get "/activeagents/api/evaluations/#{evaluation.id}/scenarios"
    assert_response :success
    assert_equal [ "A" ], JSON.parse(response.body)["groups"]

    put "/activeagents/api/evaluations/#{evaluation.id}/scenarios", params: { scenarios_text: "# A\nFirst, reworded\n# B\nSecond" }, as: :json
    assert_response :success
    assert_equal %w[a_1 b_1], evaluation.scenarios.ordered.map(&:key)

    scenario = evaluation.scenarios.find_by!(key: "b_1")
    patch "/activeagents/api/evaluations/#{evaluation.id}/scenarios/#{scenario.id}", params: { scenario: { enabled: false, expectations: { tools: [ "fetch_url" ] } } }, as: :json
    assert_response :success
    assert_not scenario.reload.enabled
    assert_equal [ "fetch_url" ], scenario.expected_tools

    delete "/activeagents/api/evaluations/#{evaluation.id}/scenarios/#{scenario.id}"
    assert_response :no_content
    assert_equal [ "a_1" ], evaluation.scenarios.map(&:key)
  end

  test "replacing with an empty paste is refused" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "a_1", prompt: "First")
    evaluation.save!

    put "/activeagents/api/evaluations/#{evaluation.id}/scenarios", params: { scenarios_text: "   " }, as: :json

    assert_response :unprocessable_entity
    assert_equal 1, evaluation.scenarios.count
  end

  test "the index still serves a suite whose latest run is pending" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Catalog", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "a_1", prompt: "First")
    evaluation.save!
    evaluation.run_later!

    get "/activeagents/api/evaluations", params: { agent_id: agent.id }

    assert_response :success
    listed = JSON.parse(response.body)["evaluations"].first
    assert_equal "pending", listed.dig("latest_run", "status")
    assert_nil listed.dig("latest_run", "average_score")
  end

  test "a completed run renders as a self-contained HTML report page" do
    agent = create_agent
    evaluation = agent.evaluations.create!(
      name: "Report suite", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ],
      config: { "scenario_suite" => true }
    )
    scenario = evaluation.scenarios.create!(key: "s1", prompt: "Who changed the <biography>?", group: "blame", position: 0)
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    run.scenario_results.create!(
      scenario: scenario, model: "mock-model", provider: "mock", status: :passed, score: 1.0,
      scores: { "response_present" => 1.0 }, output: "<b>Alice</b> did.", duration_ms: 10
    )

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}/report"

    assert_response :success
    assert_match %r{text/html}, response.content_type
    assert_includes response.body, "<!doctype html>"
    assert_includes response.body, "Who changed the &lt;biography&gt;?"
    assert_includes response.body, "&lt;b&gt;Alice&lt;/b&gt; did."
    assert_includes response.body, "Report suite"
  end

  test "a generation-sampling run has no report page" do
    agent = create_agent
    evaluation = agent.evaluations.create!(
      name: "Sampling", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
    )
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}/report"

    assert_response :not_found
  end

  # A complete run over one scenario that expected `tool`, with its result
  # diagnosed the way ScenarioEvaluationRunner records a tool the agent
  # could not call — the shape a run's fix items are built from.
  def create_missing_tool_run(agent, tool:)
    evaluation = agent.evaluations.new(name: "Tool coverage", judge_kind: "rules", criteria: [])
    scenario = evaluation.scenarios.build(
      key: "match_slots", prompt: "Find the next available slot", group: "match", position: 0,
      expectations: { "tools" => [ tool ] }
    )
    evaluation.save!
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current, samples_evaluated: 1, samples_passed: 0)
    recommendation = "The scenario expects #{tool}, which assistant does not have. Enable the tool (or add the server that provides it) and re-run."
    run.scenario_results.create!(
      scenario: scenario, model: "mock-model", provider: "mock", status: :failed, score: 0.5,
      scores: { "expected_tools" => 0.0 }, output: "I can't look that up.", duration_ms: 10,
      fault: "expected_tool_not_called", recommendation: recommendation,
      diagnosis: {
        "fault" => "expected_tool_not_called",
        "summary" => "Expected #{tool} to be called; assistant called nothing.",
        "recommendation" => recommendation,
        "evidence" => { "expected" => [ tool ], "called" => [], "unavailable" => [ tool ] }
      }
    )
    [ evaluation, run ]
  end

  test "a run's fix items name the catalog server behind a missing tool and whether the agent enabled it" do
    agent = create_agent
    evaluation, run = create_missing_tool_run(agent, tool: "browser_navigate")

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}"

    assert_response :success
    items = JSON.parse(response.body).dig("run", "fix_items")
    assert_equal 1, items.size
    item = items.first
    assert_equal "fault", item["kind"]
    assert_equal "expected_tool_not_called", item["fault"]
    assert_equal 1, item["count"]
    assert_equal [ "match_slots" ], item["scenario_keys"]
    assert_equal [ "mock/mock-model" ], item["models"]
    assert_equal "missing tools", item["tools_label"]
    server = { "key" => "playwright", "name" => "Playwright", "status" => "available" }
    assert_equal [ { "name" => "browser_navigate", "note" => "Playwright", "server" => server } ], item["tools"]
    assert_equal server, item["server"]
    # Paths are relative to the mount: the React app resolves them itself.
    assert_equal({ "label" => "Enable Playwright for Assistant", "hint" => "MCP Services ->", "path" => "/mcp/playwright" }, item["action"])
  end

  test "a server the agent declares in mcp_servers resolves as enabled, so the fix points at Tools" do
    agent = ActionAgent::Agent.create!(
      name: "Assistant", provider: "mock", model: "mock-model",
      mcp_servers: [ { "name" => "playwright", "transport" => "stdio", "command" => "npx @playwright/mcp@latest" } ]
    )
    evaluation, run = create_missing_tool_run(agent, tool: "browser_navigate")

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}"

    assert_response :success
    item = JSON.parse(response.body).dig("run", "fix_items").first
    assert_equal "enabled", item.dig("server", "status")
    assert_equal "enabled", item.dig("tools", 0, "server", "status")
    assert_equal({ "label" => "Open tools", "hint" => "Tools ->", "path" => "/tools" }, item["action"])
  end

  test "a failing namespaced tool names its server even when nothing else knows it" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Tool coverage", judge_kind: "rules", criteria: [])
    scenario = evaluation.scenarios.build(
      key: "sync", prompt: "Is sync healthy?", position: 0, expectations: { "tools" => [ "mcp__booking__sync_status" ] }
    )
    evaluation.save!
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    run.scenario_results.create!(
      scenario: scenario, model: "mock-model", provider: "mock", status: :failed, score: 0.5, fault: "tool_error",
      tool_calls: [ { "name" => "mcp__booking__sync_status", "error" => true, "detail" => "no Provider with id=0" } ],
      recommendation: "Fix the failing tool before judging the answer.",
      diagnosis: {
        "fault" => "tool_error", "summary" => "Tool mcp__booking__sync_status returned an error while answering.",
        "recommendation" => "Fix the failing tool before judging the answer.",
        "evidence" => { "tools" => [ "mcp__booking__sync_status" ], "detail" => "no Provider with id=0" }
      }
    )

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}"

    assert_response :success
    item = JSON.parse(response.body).dig("run", "fix_items").first
    assert_equal "failing tools", item["tools_label"]
    assert_equal(
      [ { "name" => "mcp__booking__sync_status", "note" => "no Provider with id=0",
          "server" => { "key" => "booking", "name" => "booking", "status" => "unknown" } } ],
      item["tools"]
    )
    assert_nil item["server"]
    assert_equal({ "label" => "Open failing tools", "hint" => "Tools ->", "path" => "/tools" }, item["action"])
  end

  test "a generation-sampling run serializes an empty fix list" do
    agent = create_agent
    evaluation = agent.evaluations.create!(
      name: "Sampling", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
    )
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}"

    assert_response :success
    assert_equal [], JSON.parse(response.body).dig("run", "fix_items")
  end

  test "the report page pins the theme from ?theme and links fix actions at the mount" do
    agent = create_agent
    evaluation, run = create_missing_tool_run(agent, tool: "browser_navigate")

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}/report", params: { theme: "dark" }

    assert_response :success
    assert_includes response.body, '<html lang="en" class="theme-dark">'
    assert_includes response.body, 'href="/activeagents/mcp/playwright"'
    assert_includes response.body, "Enable Playwright for Assistant"

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}/report", params: { theme: "light" }

    assert_response :success
    assert_includes response.body, '<html lang="en" class="theme-light">'

    # No theme, or one the report does not know, follows the viewer's own.
    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}/report", params: { theme: "neon" }

    assert_response :success
    assert_includes response.body, '<html lang="en">'
  end
  # The report page is rebuilt from the run's persisted results rather than
  # re-ranked, so it names the same best model and judge the suite panel
  # does — the panel reads scores["_verdict"]. Here the recorded winner is
  # the model that failed its only scenario: ranking again would pick the
  # other one.
  test "the report page names the judge's pick and the judge the run recorded" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Bake-off", judge_kind: "rules", judge_model: "gpt-4o-mini", criteria: [])
    scenario = evaluation.scenarios.build(key: "find_slots", prompt: "Which slots are open?", position: 0)
    evaluation.save!
    run = evaluation.evaluation_runs.create!(
      status: :complete, completed_at: Time.current,
      selection: {
        "scenario_ids" => [ scenario.id ],
        "models" => [
          { "label" => "gpt-5-mini", "provider" => "openai", "model" => "gpt-5-mini" },
          { "label" => "ollama/qwen3:8b", "provider" => "ollama", "model" => "qwen3:8b" }
        ]
      },
      scores: {
        "_verdict" => { "winner" => "gpt-5-mini", "rationale" => "Called find_records every time.", "judge" => "claude-sonnet-4-5" }
      }
    )
    run.scenario_results.create!(
      scenario: scenario, model: "gpt-5-mini", provider: "openai", status: :failed, score: 0.0,
      output: "No idea.", duration_ms: 700
    )
    run.scenario_results.create!(
      scenario: scenario, model: "qwen3:8b", provider: "ollama", status: :passed, score: 1.0,
      output: "Next Tuesday.", duration_ms: 2400
    )

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}/report"

    assert_response :success
    assert_equal [ [ "gpt-5-mini" ] ], response.body.scan(%r{<span class="name">([^<]+)</span>[^\n]*judge's pick})
    assert_includes response.body, "judged by claude-sonnet-4-5"
    assert_includes response.body, "Called find_records every time."
    refute_includes response.body, "judged by pass rate"
  end
end
