# frozen_string_literal: true

require "test_helper"

# EvaluationRun#average_score reads a scores payload that is not uniformly
# { criterion => stats }: a comparison run writes "_"-prefixed metadata and
# cohort maps of model => stats alongside plain criterion hashes.
class ActionAgentEvaluationRunTest < ActiveSupport::TestCase
  def run_with(scores)
    ActionAgent::EvaluationRun.new(scores: scores)
  end

  test "plain criterion stats are averaged" do
    run = run_with(
      "response_present" => { "score" => 1.0, "min" => 1.0, "max" => 1.0, "passed" => 2, "total" => 2 },
      "latency" => { "score" => 0.5, "min" => 0.5, "max" => 0.5, "passed" => 0, "total" => 2 }
    )

    assert_in_delta 0.75, run.average_score, 0.0001
  end

  test "skipped criteria carry no score and drop out of the average" do
    run = run_with(
      "llm_judge" => { "skipped" => true, "reason" => "No judge provider configured" },
      "latency" => { "score" => 0.4, "min" => 0.4, "max" => 0.4, "passed" => 0, "total" => 1 }
    )

    assert_in_delta 0.4, run.average_score, 0.0001
  end

  # Regression: EvaluationRunnerService#score_comparison writes
  # scores["_missing_models"] = ["gpt-4o"] (an Array) for a comparison run
  # whose cohorts have no generations. average_score used to call
  # Array#[]("score"), raising TypeError and permanently 500-ing
  # GET <mount>/api/evaluations.
  test "_missing_models does not raise and is excluded from the average" do
    run = run_with(
      "response_present" => { "score" => 0.8, "min" => 0.8, "max" => 0.8, "passed" => 1, "total" => 1 },
      "_missing_models" => [ "gpt-4o" ]
    )

    assert_nothing_raised { run.average_score }
    assert_in_delta 0.8, run.average_score, 0.0001
  end

  test "a model summary that recorded its priced count is served as recorded" do
    summaries = { "fast" => { "scenarios" => 3, "cost" => 0.003, "priced" => 2 } }

    assert_equal summaries, run_with("_models" => summaries).model_summaries
  end

  test "a generation-sampling run has no model summaries" do
    assert_equal({}, run_with("_cohorts" => { "gpt-4o-mini" => { "samples" => 2 } }).model_summaries)
  end

  test "underscore metadata alone averages to nil rather than raising" do
    run = run_with("_missing_models" => [ "gpt-4o", "no-such-model" ])

    assert_nil run.average_score
  end

  test "a comparison cohort map averages its per-model scores" do
    run = run_with(
      "response_present" => {
        "gpt-4o-mini" => { "score" => 1.0, "min" => 1.0, "max" => 1.0, "passed" => 2, "total" => 2 },
        "claude-haiku" => { "score" => 0.6, "min" => 0.6, "max" => 0.6, "passed" => 1, "total" => 2 }
      }
    )

    assert_in_delta 0.8, run.average_score, 0.0001
  end

  test "a comparison run averages cohort maps alongside metadata and a verdict" do
    run = run_with(
      "response_present" => {
        "gpt-4o-mini" => { "score" => 1.0, "total" => 2 },
        "claude-haiku" => { "score" => 0.6, "total" => 2 }
      },
      "latency" => {
        "gpt-4o-mini" => { "score" => 0.4, "total" => 2 },
        "claude-haiku" => { "score" => 0.8, "total" => 2 }
      },
      "_missing_models" => [ "no-such-model" ],
      "_verdict" => { "winner" => "gpt-4o-mini", "rationale" => "Fewer empty answers." }
    )

    # (1.0 + 0.6) / 2 = 0.8 and (0.4 + 0.8) / 2 = 0.6, averaged => 0.7
    assert_in_delta 0.7, run.average_score, 0.0001
  end

  test "a cohort whose models were all skipped contributes no score" do
    run = run_with(
      "llm_judge" => {
        "gpt-4o-mini" => { "skipped" => true, "reason" => "No judge provider configured" },
        "claude-haiku" => { "skipped" => true, "reason" => "No judge provider configured" }
      },
      "latency" => { "score" => 0.9, "total" => 1 }
    )

    assert_in_delta 0.9, run.average_score, 0.0001
  end

  test "an empty scores payload averages to nil" do
    assert_nil run_with({}).average_score
  end
end

# The Evaluations index serializes the latest run of every listed evaluation,
# so a single unaverageable run used to take the whole page down.
class ActionAgentEvaluationsIndexTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
  end

  test "the index survives a comparison run that records _missing_models" do
    agent = ActionAgent::Agent.create!(name: "Comparer", provider: "openai", model: "gpt-4o-mini")
    evaluation = agent.evaluations.create!(
      name: "Model bake-off",
      judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ],
      config: { "compare_models" => [ "gpt-4o-mini", "no-such-model" ] }
    )
    evaluation.evaluation_runs.create!(
      status: :complete,
      scores: {
        "response_present" => {
          "gpt-4o-mini" => { "score" => 1.0, "min" => 1.0, "max" => 1.0, "passed" => 2, "total" => 2 }
        },
        "_missing_models" => [ "no-such-model" ]
      },
      samples_evaluated: 2,
      samples_passed: 2,
      completed_at: Time.current
    )

    get "/activeagents/api/evaluations"

    assert_response :success
    body = JSON.parse(response.body)
    latest = body["evaluations"].first["latest_run"]
    assert_in_delta 1.0, latest["average_score"], 0.0001
    assert_equal [ "no-such-model" ], latest.dig("scores", "_missing_models")
  end

  test "a scenario run serializes its aggregated usage" do
    agent = ActionAgent::Agent.create!(name: "Assistant", provider: "mock", model: "mock-model")
    evaluation = agent.evaluations.create!(
      name: "Suite", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ],
      config: { "scenario_suite" => true }
    )
    scenario = evaluation.scenarios.create!(key: "s1", prompt: "Hello", position: 0)
    judge = { "calls" => 3, "input_tokens" => 600, "output_tokens" => 30, "cost" => 0.00375, "model" => "claude-opus-5",
              "by_kind" => { "score" => 2, "verdict" => 1 } }
    run = evaluation.evaluation_runs.create!(status: :complete, created_at: 90.seconds.ago, completed_at: Time.current,
      scores: { "_judge_usage" => judge })
    run.scenario_results.create!(
      scenario: scenario, model: "mock-model", status: :passed, score: 1.0,
      duration_ms: 1200, input_tokens: 100, output_tokens: 40, cost: 0.002
    )
    run.scenario_results.create!(
      scenario: scenario, model: "mock-fast", status: :failed, score: 0.5,
      duration_ms: 800, input_tokens: 60, output_tokens: 20, cost: 0.001
    )

    get "/activeagents/api/evaluations"

    assert_response :success
    usage = JSON.parse(response.body)["evaluations"].first.dig("latest_run", "usage")
    assert_equal 2, usage["replays"]
    assert_equal 2, usage["priced"]
    assert_equal 0, usage["unpriced"]
    assert_in_delta 0.003, usage["cost"], 0.00001
    # The operating figure: what one replayed interaction cost the agent.
    assert_in_delta 0.0015, usage["per_interaction"], 0.00001
    assert_equal 160, usage["input_tokens"]
    assert_equal 60, usage["output_tokens"]
    assert_equal 2000, usage["model_time_ms"]
    assert_in_delta 90_000, usage["runtime_ms"], 2_000
    # The judge's spend rides alongside, never folded into the replays' cost,
    # and says it is the engine's meter; `total` is the two together.
    assert_equal judge.merge("source" => "meter", "estimated" => true, "run" => { "calls" => 1, "cost" => nil, "by_kind" => { "verdict" => 1 } }), usage["judge"]
    assert_in_delta 0.003 + judge["cost"], usage["total"], 1e-9
    assert_equal "estimated", usage["cost_basis"], "the engine priced its own replays from tokens"
  end

  # A scenario run whose replays carry `costs`, one per replay; nil is a
  # replay with no cost estimate.
  def scenario_run_costing(*costs)
    agent = ActionAgent::Agent.create!(name: "Assistant", provider: "mock", model: "mock-model")
    evaluation = agent.evaluations.create!(
      name: "Suite", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ],
      config: { "scenario_suite" => true }
    )
    scenario = evaluation.scenarios.create!(key: "s1", prompt: "Hello", position: 0)
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    costs.each_with_index do |cost, index|
      run.scenario_results.create!(
        scenario: scenario, model: "model-#{index}", status: :passed, score: 1.0,
        duration_ms: 500, input_tokens: 100, output_tokens: 40, cost: cost
      )
    end
    run
  end

  # A replay that recorded no cost is priced from its tokens at its model's
  # rate (model-2 is unknown, so the default $1/$4 per million applies),
  # so the run's cost covers every replay.
  test "a scenario run with a replay that recorded no cost prices it from its tokens and counts how" do
    scenario_run_costing(0.002, 0.001, nil)

    get "/activeagents/api/evaluations"

    assert_response :success
    usage = JSON.parse(response.body)["evaluations"].first.dig("latest_run", "usage")
    assert_equal 3, usage["replays"]
    assert_equal 3, usage["priced"]
    assert_equal 0, usage["unpriced"]
    assert_equal 3, usage["estimated"], "the engine's stored costs are estimates too"
    assert_equal 0, usage["reported"]
    assert_in_delta 0.003 + 0.00026, usage["cost"], 1e-9, "the cost covers the replay that recorded none"
    assert_in_delta (0.003 + 0.00026) / 3, usage["per_interaction"], 1e-6
    assert_equal "estimated", usage["cost_basis"]
    assert_equal 300, usage["input_tokens"]
  end

  test "a scenario run whose replays recorded no cost is priced from their tokens rather than left blank" do
    usage = scenario_run_costing(nil, nil).usage

    assert_equal 2, usage[:replays]
    assert_equal 2, usage[:priced]
    assert_equal 0, usage[:unpriced]
    assert_in_delta 0.00052, usage[:cost], 1e-9, "100 in × $1/M + 40 out × $4/M, twice"
    assert_in_delta 0.00026, usage[:per_interaction], 1e-9
    assert_equal 1_000, usage[:model_time_ms]
  end

  # The summaries are served with their costs as they stand now: a replay
  # that recorded no cost and no tokens is priced from its text (the prompt,
  # here) as a lower bound, so every result is priced and every summary says
  # how.
  test "a scenario run's model summaries are served with the effective cost and the counts behind it, per label" do
    run = scenario_run_costing
    scenario = run.evaluation.scenarios.first
    run.update!(
      selection: { "models" => [ { "label" => "fast", "provider" => "openai", "model" => "gpt-fast" } ] },
      scores: {
        "_models" => {
          "fast" => { "scenarios" => 3, "passed" => 3, "cost" => 0.003 },
          "ollama/llama" => { "scenarios" => 1, "passed" => 1, "cost" => nil }
        }
      }
    )
    [ 0.002, 0.001, nil ].each do |cost|
      run.scenario_results.create!(scenario: scenario, provider: "openai", model: "gpt-fast", status: :passed, score: 1.0, cost: cost)
    end
    run.scenario_results.create!(scenario: scenario, provider: "ollama", model: "llama", status: :passed, score: 1.0, cost: nil)

    get "/activeagents/api/evaluations"

    assert_response :success
    models = JSON.parse(response.body)["evaluations"].first.dig("latest_run", "scores", "_models")
    fast = models["fast"]
    assert_equal [ 3, 0, 3, 3, nil, 0 ], fast.values_at("priced", "reported", "estimated", "passed", "judge_cost", "judge_calls"), "the label the selection gave openai/gpt-fast"
    assert_operator fast["cost"], :>, 0.003, "the replay that recorded no cost adds its text estimate"
    assert_equal [ 1, 1 ], models.dig("ollama/llama").values_at("priced", "estimated"), "the label naming the result's provider and model"
    assert_not_nil models.dig("ollama/llama", "cost"), "a one-token prompt rounds to $0.000000, but is priced"
  end

  test "a run that recorded nothing reports no usage" do
    run = ActionAgent::EvaluationRun.new
    assert_nil run.usage
  end

  # A sampling run's agent-side figure is what the sampled interactions cost
  # to serve — already spent before the run — while the judge's is the run's
  # own; the two never merge into one number.
  test "a generation-sampling run reports its cohorts' cost per interaction apart from the judge's" do
    judge = { "calls" => 21, "input_tokens" => 6_300, "output_tokens" => 252, "cost" => 0.0378, "model" => "claude-opus-5",
              "by_kind" => { "score" => 20, "verdict" => 1 } }
    run = ActionAgent::EvaluationRun.new(
      created_at: 30.seconds.ago, completed_at: Time.current,
      scores: {
        "quality" => { "score" => 0.9, "min" => 0.8, "max" => 1.0, "passed" => 18, "total" => 20 },
        "_cohorts" => {
          "gpt-4o-mini" => { "samples" => 12, "passed" => 11, "input_tokens" => 1_200, "output_tokens" => 480, "cost" => 0.0006 },
          "gpt-4o" => { "samples" => 8, "passed" => 7, "input_tokens" => 800, "output_tokens" => 320, "cost" => 0.0052 }
        },
        "_judge_usage" => judge
      }
    )

    usage = run.usage
    assert_equal 20, usage[:samples]
    assert_nil usage[:replays]
    # These cohorts predate the "priced" count: a cohort with a cost counts
    # every sample as priced.
    assert_equal 20, usage[:priced]
    assert_equal 0, usage[:unpriced]
    assert_in_delta 0.0058, usage[:cost], 1e-9
    assert_in_delta 0.0058 / 20, usage[:per_interaction], 1e-9
    assert_equal 2_000, usage[:input_tokens]
    assert_equal 800, usage[:output_tokens]
    assert_in_delta 30_000, usage[:runtime_ms], 2_000
    assert_equal judge.merge("source" => "meter", "estimated" => true, "run" => { "calls" => 1, "cost" => nil, "by_kind" => { "verdict" => 1 } }), usage[:judge]
    assert_equal "estimated", usage[:cost_basis]
    assert_in_delta 0.0058 + judge["cost"], usage[:total], 1e-9
  end

  test "a generation-sampling run prices per interaction over the samples its cohorts priced" do
    run = ActionAgent::EvaluationRun.new(
      scores: {
        "_cohorts" => {
          "gpt-4o-mini" => { "samples" => 12, "passed" => 11, "input_tokens" => 1_200, "output_tokens" => 480, "cost" => 0.0006, "priced" => 10 },
          "unknown" => { "samples" => 8, "passed" => 7, "input_tokens" => 0, "output_tokens" => 0, "cost" => nil, "priced" => 0 }
        }
      }
    )

    usage = run.usage
    assert_equal 20, usage[:samples]
    assert_equal 10, usage[:priced]
    assert_equal 10, usage[:unpriced]
    assert_in_delta 0.0006, usage[:cost], 1e-9
    assert_in_delta 0.0006 / 10, usage[:per_interaction], 1e-9
  end

  test "a generation-sampling run with nothing priced reports no cost" do
    run = ActionAgent::EvaluationRun.new(
      scores: { "_cohorts" => { "unknown" => { "samples" => 4, "passed" => 4, "cost" => nil, "priced" => 0 } } }
    )

    usage = run.usage
    assert_equal 4, usage[:samples]
    assert_equal 0, usage[:priced]
    assert_equal 4, usage[:unpriced]
    assert_nil usage[:cost]
    assert_nil usage[:per_interaction]
  end

  test "a run that only asked a judge reports the judge's spend and nothing on the agent's side" do
    judge = { "calls" => 1, "input_tokens" => 500, "output_tokens" => 80, "cost" => 0.0045, "model" => "claude-opus-5",
              "by_kind" => { "define" => 1 } }
    run = ActionAgent::EvaluationRun.new(scores: { "_judge_usage" => judge })

    metered = judge.merge("source" => "meter", "estimated" => true, "run" => { "calls" => 1, "cost" => nil, "by_kind" => { "define" => 1 } })
    assert_equal({ judge: metered, total: 0.0045 }, run.usage)
  end
end

# EvaluationToolResolver names the MCP server behind a tool a run's fix
# items mention, and whether the evaluated agent has that server enabled.
class ActionAgentEvaluationToolResolverTest < ActiveSupport::TestCase
  def resolver(agent = ActionAgent::Agent.new(name: "Assistant"))
    ActionAgent::EvaluationToolResolver.new(agent)
  end

  test "a namespaced tool names its server outright" do
    assert_equal(
      { "key" => "playwright", "name" => "Playwright", "status" => "available" },
      resolver.call("mcp__playwright__browser_click")
    )
  end

  test "a namespaced server nothing else knows is named, with no status" do
    assert_equal(
      { "key" => "shipping-desk", "name" => "shipping-desk", "status" => nil },
      resolver.call("mcp__shipping-desk__track_shipment")
    )
  end

  test "a bare tool the catalog hints at maps to that server" do
    assert_equal({ "key" => "filesystem", "name" => "Filesystem", "status" => "available" }, resolver.call("read_file"))
  end

  test "a host-registered catalog server is available for the tools it hints" do
    ActionAgent.mcp_catalog = [ { key: "shipping-desk", name: "Shipping Desk", tool_hints: %w[track_shipment] } ]

    assert_equal({ "key" => "shipping-desk", "name" => "Shipping Desk", "status" => "available" }, resolver.call("track_shipment"))
  ensure
    ActionAgent.mcp_catalog = []
  end

  test "a server the agent declares by name is enabled, whatever the case" do
    agent = ActionAgent::Agent.new(name: "Assistant", mcp_servers: [ "Playwright" ])

    assert_equal({ "key" => "playwright", "name" => "Playwright", "status" => "enabled" }, resolver(agent).call("browser_navigate"))
    assert_equal "enabled", resolver(agent).call("mcp__playwright__browser_click")["status"]
  end

  test "a configured server hash that lists its tools resolves them under its own display name" do
    agent = ActionAgent::Agent.new(
      name: "Assistant",
      mcp_servers: [ {
        "key" => "shipping", "name" => "Shipping Desk", "url" => "https://shipping.test/mcp",
        "tools" => [ "track_shipment", { "name" => "schedule_pickup" } ]
      } ]
    )

    assert_equal({ "key" => "shipping", "name" => "Shipping Desk", "status" => "enabled" }, resolver(agent).call("track_shipment"))
    assert_equal "shipping", resolver(agent).call("schedule_pickup")["key"]
  end

  test "the older hash-keyed configuration is read the same way" do
    agent = ActionAgent::Agent.new(
      name: "Assistant",
      mcp_servers: { "playwright" => { "command" => "npx @playwright/mcp@latest" }, "shipping" => { "tools" => [ "track_shipment" ] } }
    )

    assert_equal "enabled", resolver(agent).call("mcp__playwright__browser_click")["status"]
    assert_equal({ "key" => "shipping", "name" => "shipping", "status" => "enabled" }, resolver(agent).call("track_shipment"))
  end

  test "an agent-defined tool, a blank name and malformed entries resolve to nothing" do
    agent = ActionAgent::Agent.new(name: "Assistant", mcp_servers: [ 42, [ "playwright" ], nil, { "url" => "https://x.test" } ])

    assert_nil resolver(agent).call("lookup_order")
    assert_nil resolver(agent).call("")
    assert_nil resolver(nil).call("lookup_order")
  end
end

# EvaluationRun#to_report hands the framework's Report what its fix items
# need from the dashboard: the agent's name, a resolver for its MCP servers
# and the dashboard's routes.
class ActionAgentEvaluationRunReportTest < ActiveSupport::TestCase
  def setup
    ActionAgent::Agent.delete_all
  end

  def create_run(agent)
    # A scenario suite carries no criteria of its own — it is scored by its
    # scenarios' expectations — so the scenario is built before the first
    # save, which is when that validation runs.
    evaluation = agent.evaluations.new(name: "Tool coverage", judge_kind: "rules", criteria: [])
    scenario = evaluation.scenarios.build(
      key: "order_status", prompt: "Where is order ABC-123?", position: 0, expectations: { "tools" => [ "browser_navigate" ] }
    )
    evaluation.save!
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    run.scenario_results.create!(
      scenario: scenario, model: "mock-model", provider: "mock", status: :failed, score: 0.5,
      fault: "expected_tool_not_called", recommendation: "Enable the tool and re-run.",
      diagnosis: {
        "fault" => "expected_tool_not_called",
        "summary" => "Expected browser_navigate to be called; assistant called nothing.",
        "recommendation" => "Enable the tool and re-run.",
        "evidence" => { "expected" => [ "browser_navigate" ], "called" => [], "unavailable" => [ "browser_navigate" ] }
      }
    )
    run
  end

  test "the report carries the agent, its tool resolver and mount-relative links" do
    agent = ActionAgent::Agent.create!(name: "Assistant", provider: "mock", model: "mock-model", mcp_servers: [ "playwright" ])
    run = create_run(agent)

    report = run.to_report

    assert_equal "Assistant", report.agent_name
    assert_kind_of ActionAgent::EvaluationToolResolver, report.tool_resolver
    assert_equal({ "mcp" => "/mcp/%{key}", "tools" => "/tools", "instructions" => "/agents/#{agent.id}/edit" }, report.links)
    assert_equal "Assistant", report.metadata["agent"]
  end

  test "fix_items delegates to the report with the agent's servers resolved" do
    agent = ActionAgent::Agent.create!(name: "Assistant", provider: "mock", model: "mock-model", mcp_servers: [ "playwright" ])
    run = create_run(agent)

    item = run.fix_items.first

    assert_equal "expected_tool_not_called", item["fault"]
    assert_equal({ "key" => "playwright", "name" => "Playwright", "status" => "enabled" }, item["server"])
    assert_equal "/tools", item.dig("action", "path")
  end

  test "report_links prefixes the dashboard mount for the standalone report page" do
    agent = ActionAgent::Agent.create!(name: "Assistant", provider: "mock", model: "mock-model")
    run = create_run(agent)

    links = run.report_links(mount: "/activeagents/")

    assert_equal "/activeagents/mcp/%{key}", links["mcp"]
    assert_equal "/activeagents/tools", links["tools"]
    assert_equal "/activeagents/agents/#{agent.id}/edit", links["instructions"]
    assert_equal "Enable Playwright for Assistant", run.fix_items(links: links).first.dig("action", "label")
    assert_equal "/activeagents/mcp/playwright", run.fix_items(links: links).first.dig("action", "path")
  end

  test "a run without scenario results has no fix items" do
    agent = ActionAgent::Agent.create!(name: "Assistant", provider: "mock", model: "mock-model")
    evaluation = agent.evaluations.create!(
      name: "Sampling", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
    )
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)

    assert_equal [], run.fix_items
  end
end

# A report rebuilt from a run has to render the verdict that run recorded
# rather than rank the rebuilt results again: the dashboard's suite panel
# reads the same scores["_verdict"], and the report page and the panel
# naming two different best models — or two different judges — is the
# regression these cover.
class ActionAgentEvaluationRunVerdictTest < ActiveSupport::TestCase
  HOSTED = { "label" => "gpt-5-mini", "provider" => "openai", "model" => "gpt-5-mini" }.freeze
  LOCAL = { "label" => "ollama/qwen3:8b", "provider" => "ollama", "model" => "qwen3:8b" }.freeze

  # The model block the report badges as the judge's pick. Each block's
  # headline is one line: name, provider, then the badge when it is picked.
  PICKED = %r{<span class="name">([^<]+)</span>[^\n]*judge's pick}

  def setup
    ActionAgent::Agent.delete_all
  end

  # Two scenarios × two models where the local model passes both and
  # gpt-5-mini only one, so ranking the rebuilt results by pass rate picks
  # ollama/qwen3:8b: a report that still names gpt-5-mini can only have read
  # the verdict the run recorded.
  def create_comparison_run(verdict: nil, judge_model: nil, models: [ HOSTED, LOCAL ])
    agent = ActionAgent::Agent.create!(name: "Assistant", provider: "openai", model: "gpt-5-mini")
    evaluation = agent.evaluations.new(name: "Bake-off", judge_kind: "rules", judge_model: judge_model, criteria: [])
    evaluation.scenarios.build(key: "find_order", prompt: "Find order ABC-123", position: 0)
    evaluation.scenarios.build(key: "cancel_order", prompt: "Cancel it", position: 1)
    evaluation.save!

    run = evaluation.evaluation_runs.create!(
      status: :complete, completed_at: Time.current,
      selection: { "scenario_ids" => evaluation.scenarios.map(&:id), "models" => models }.compact,
      scores: {
        "_models" => {
          "gpt-5-mini" => { "scenarios" => 2, "passed" => 1, "pass_rate" => 0.5 },
          "ollama/qwen3:8b" => { "scenarios" => 2, "passed" => 2, "pass_rate" => 1.0 }
        },
        "_verdict" => verdict
      }.compact
    )
    evaluation.scenarios.ordered.each_with_index do |scenario, index|
      run.scenario_results.create!(
        scenario: scenario, model: "gpt-5-mini", provider: "openai", status: index.zero? ? :passed : :failed,
        score: index.zero? ? 1.0 : 0.0, output: "answered", duration_ms: 900
      )
      run.scenario_results.create!(
        scenario: scenario, model: "qwen3:8b", provider: "ollama", status: :passed, score: 1.0,
        output: "answered", duration_ms: 2400
      )
    end
    run
  end

  test "the report names the judge's pick and the judge the run recorded, not a fresh pass-rate ranking" do
    verdict = { "winner" => "gpt-5-mini", "rationale" => "Called the right tool every time.", "judge" => "claude-sonnet-4-5" }
    run = create_comparison_run(verdict: verdict, judge_model: "gpt-4o-mini")

    report = run.to_report
    html = report.to_html

    assert_equal verdict, run.recorded_verdict
    assert_equal "claude-sonnet-4-5", run.judge_label
    assert_equal "gpt-5-mini", report.winner
    assert_equal [ [ "gpt-5-mini" ] ], html.scan(PICKED)
    assert_includes html, "judge&#39;s pick · gpt-5-mini"
    assert_includes html, "judged by claude-sonnet-4-5"
    assert_includes html, "Called the right tool every time."
    assert_includes html, "judge claude-sonnet-4-5"
  end

  # "pass rate" is the framework's label for a ranking no judge ruled on, so
  # it is not a judge to name — the panel falls through to the evaluation's
  # judge model there, and so does the report.
  test "a verdict the framework ranked itself is judged by the evaluation's judge model" do
    run = create_comparison_run(
      verdict: { "winner" => "gpt-5-mini", "rationale" => "Passed 1 of 2 scenarios.", "judge" => "pass rate" },
      judge_model: "gpt-4o-mini"
    )

    html = run.to_report.to_html

    assert_equal "gpt-4o-mini", run.judge_label
    assert_equal [ [ "gpt-5-mini" ] ], html.scan(PICKED)
    assert_includes html, "judged by gpt-4o-mini"
    assert_includes html, "judge gpt-4o-mini"
    refute_includes html, "judged by pass rate"
  end

  # Nothing to carry over: the report ranks the results itself, as a CLI run
  # does, and names the rules that scored them.
  test "a run that recorded no verdict still renders" do
    run = create_comparison_run

    assert_nil run.recorded_verdict
    assert_nil run.judge_label

    html = run.to_report.to_html

    assert_includes html, "<!doctype html>"
    assert_includes html, "judged by rules"
    refute_includes html, "judged by pass rate"
    assert_equal [ [ "qwen3:8b" ] ], html.scan(PICKED)
  end

  test "a verdict that is not a hash, or is empty, is ignored rather than raising" do
    run = create_comparison_run(verdict: "gpt-5-mini", judge_model: "gpt-4o-mini")

    assert_nil run.recorded_verdict
    assert_nil create_comparison_run(verdict: {}).recorded_verdict
    assert_equal "gpt-4o-mini", run.judge_label

    html = run.to_report.to_html

    assert_includes html, "<!doctype html>"
    assert_includes html, "judged by gpt-4o-mini"
  end

  test "the rebuilt report labels its models the way the run's scores key them" do
    run = create_comparison_run(verdict: { "winner" => "gpt-5-mini", "rationale" => "Faster.", "judge" => "claude-sonnet-4-5" })

    report = run.to_report

    assert_equal [ "gpt-5-mini", "ollama/qwen3:8b" ], report.models.map(&:label)
    assert_equal run.models, report.summary_by_model.keys
  end

  # A run whose selection never recorded its specs (nothing writes one now)
  # has only the results' own provider and model to label a cohort with. The
  # report is still self-consistent — it just cannot match a recorded winner
  # to a relabelled cohort, so no block is badged.
  test "a run whose selection recorded no models labels its cohorts provider/model" do
    run = create_comparison_run(
      models: nil,
      verdict: { "winner" => "gpt-5-mini", "rationale" => "Fewer empty answers.", "judge" => "claude-sonnet-4-5" }
    )

    report = run.to_report
    html = report.to_html

    assert_equal [ "openai/gpt-5-mini", "ollama/qwen3:8b" ], report.models.map(&:label)
    assert_includes html, "<!doctype html>"
    assert_includes html, "judged by claude-sonnet-4-5"
    assert_includes html, "Fewer empty answers."
  end
end
