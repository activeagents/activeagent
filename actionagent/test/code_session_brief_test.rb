# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# CodeSessionBrief — what a coding agent is told before it touches an agent's
# code. Every judgement in it is made somewhere else and only translated
# here, so these tests seed the sources (a complete scenario run with its
# faults, the agent's telemetry, the coding agent catalog) and check the
# translation: capability gaps become needs, quality problems become
# limitations, and no credential value ever reaches the brief.
class CodeSessionBriefTest < ActiveSupport::TestCase
  TelemetryTraceTest.ensure_table!

  BRIEF = ActionAgent::CodeSessionBrief

  def setup
    ActionAgent::EvaluationScenarioResult.delete_all
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::EvaluationScenario.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::TelemetryTrace.delete_all
  end

  def teardown
    ActionAgent.provider_credentials_resolver = nil
    ActionAgent.github_token_resolver = nil
  end

  def create_agent(**attributes)
    ActionAgent::Agent.create!({
      name: "Scheduler",
      provider: "mock",
      model: "mock-model",
      instructions: "Answer scheduling questions from the practice data.",
      tools: [ "find_records" ],
      mcp_servers: [ { "name" => "sparkle", "transport" => "stdio", "command" => "npx sparkle" } ]
    }.merge(attributes))
  end

  def brief_for(agent, **options)
    BRIEF.new(**{ agent: agent, tool: "claude_code" }.merge(options))
  end

  # A complete scenario run over four scenarios and two models: the "alpha"
  # cohort carries one result per fault the brief has to tell apart, the
  # "beta" cohort passes everything so the run has a verdict to reach.
  def create_faulted_run(agent)
    evaluation = agent.evaluations.new(name: "Scheduling catalog", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "match_slots", group: "Match", position: 0,
      prompt: "Find the next available slot", expectations: { "tools" => [ "browser_navigate" ] })
    evaluation.scenarios.build(key: "remind", group: "Match", position: 1, prompt: "Remind the provider to sign")
    evaluation.scenarios.build(key: "sync_health", group: "Sync", position: 2, prompt: "Is the sync healthy?")
    evaluation.scenarios.build(key: "tone", group: "Tone", position: 3, prompt: "How many providers are unlicensed?")
    evaluation.save!

    run = evaluation.evaluation_runs.create!(
      status: :complete, completed_at: Time.current, samples_evaluated: 8, samples_passed: 4,
      scores: { "response_present" => { "score" => 0.5, "passed" => 4, "total" => 8 } }
    )

    # The tool the scenario expected and the agent could not call.
    run.scenario_results.create!(
      scenario: evaluation.scenarios.find_by!(key: "match_slots"), model: "alpha", provider: "mock",
      status: :failed, score: 0.5, scores: { "expected_tools" => 0.0 }, output: "I can't look that up.",
      duration_ms: 20, fault: "expected_tool_not_called",
      recommendation: "The scenario expects browser_navigate, which Scheduler does not have.",
      diagnosis: {
        "fault" => "expected_tool_not_called",
        "summary" => "Expected browser_navigate to be called; Scheduler called nothing.",
        "recommendation" => "The scenario expects browser_navigate, which Scheduler does not have. " \
                            "Enable the tool (or add the server that provides it) and re-run.",
        "evidence" => { "expected" => [ "browser_navigate" ], "called" => [], "unavailable" => [ "browser_navigate" ] }
      }
    )

    # A capability the judge named but nothing in the toolset provides.
    run.scenario_results.create!(
      scenario: evaluation.scenarios.find_by!(key: "remind"), model: "alpha", provider: "mock",
      status: :failed, score: 0.4, scores: { "response_present" => 1.0 }, output: "I cannot contact anyone.",
      duration_ms: 18, fault: "missing_capability",
      recommendation: "Give Scheduler a way to send reminders.",
      diagnosis: {
        "fault" => "missing_capability",
        "summary" => "Scheduler has no way to reach a provider.",
        "recommendation" => "Give Scheduler a way to send reminders.",
        "evidence" => { "tools_available" => [ "find_records" ] },
        "judge" => {
          "suggested_tool" => { "name" => "send_provider_reminder", "description" => "Message a provider" }
        }
      }
    )

    # A tool the agent has, that errored in use.
    run.scenario_results.create!(
      scenario: evaluation.scenarios.find_by!(key: "sync_health"), model: "alpha", provider: "mock",
      status: :failed, score: 0.3, scores: { "tools_succeeded" => 0.0 }, output: "Something went wrong.",
      duration_ms: 25, fault: "tool_error",
      recommendation: "Fix the failing tool before judging the answer.",
      tool_calls: [ { "name" => "find_records", "error" => true, "detail" => "no Physician with id=0" } ],
      diagnosis: {
        "fault" => "tool_error",
        "summary" => "Tool find_records returned an error while answering.",
        "recommendation" => "Fix the failing tool before judging the answer.",
        "evidence" => { "tools" => [ "find_records" ], "detail" => "no Physician with id=0" }
      }
    )

    # A quality problem the judge would fix in the instructions.
    run.scenario_results.create!(
      scenario: evaluation.scenarios.find_by!(key: "tone"), model: "alpha", provider: "mock",
      status: :failed, score: 0.4, scores: { "response_present" => 1.0 }, output: "It depends.",
      duration_ms: 15, fault: "low_quality",
      recommendation: "Answer with the record count before any caveat.",
      diagnosis: {
        "fault" => "low_quality",
        "summary" => "The answer hedged instead of answering.",
        "recommendation" => "Answer with the record count before any caveat.",
        "judge" => { "instruction_change" => "Always answer with the record count before any caveat." }
      }
    )

    evaluation.scenarios.ordered.each do |scenario|
      run.scenario_results.create!(
        scenario: scenario, model: "beta", provider: "mock", status: :passed, score: 1.0,
        scores: { "response_present" => 1.0 }, output: "Done.", duration_ms: 12
      )
    end

    [ evaluation, run ]
  end

  # A trace as the ingest endpoint would have stored it, in the shape
  # MetricsApiTest builds: a root span plus the llm span carrying the model.
  def create_trace(agent_class:, status: "OK", error: nil, duration: 300, at: Time.current)
    ActionAgent::TelemetryTrace.create!(
      trace_id: SecureRandom.hex(16), service_name: "dummy", environment: "production", timestamp: at,
      spans: [
        {
          "span_id" => "r1", "parent_span_id" => nil, "name" => "#{agent_class}.respond", "type" => "root",
          "duration_ms" => duration, "status" => status,
          "attributes" => { "agent.class" => agent_class, "agent.action" => "respond", "error.message" => error }.compact
        },
        {
          "span_id" => "l1", "parent_span_id" => "r1", "name" => "llm.generate", "type" => "llm",
          "duration_ms" => duration, "status" => "OK",
          "attributes" => { "llm.model" => "mock-model", "llm.provider" => "mock" }
        }
      ],
      total_duration_ms: duration, total_input_tokens: 10, total_output_tokens: 5,
      status: status, agent_class: agent_class, agent_action: "respond", error_message: error
    )
  end

  # The brief falls back to the process environment for a credential on a
  # single-tenant install, so a test about missing credentials has to own it.
  def without_env(*names)
    saved = names.to_h { |name| [ name, ENV[name] ] }
    names.each { |name| ENV.delete(name) }
    yield
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  # --- needs --------------------------------------------------------------

  test "a capability gap becomes a need naming the missing tool, its server and the evidence behind it" do
    agent = create_agent
    _evaluation, run = create_faulted_run(agent)

    needs = brief_for(agent, evaluation_run: run).to_h["needs"]

    missing = needs.find { |need| need["tools"].include?("browser_navigate") }
    assert missing, "no need named the tool the scenario expected: #{needs.inspect}"
    assert_equal "mcp_server", missing["kind"]
    assert_equal({ "key" => "playwright", "name" => "Playwright", "status" => "available" }, missing["server"])
    assert_match(/Playwright/, missing["title"])
    assert_equal(
      { "fault" => "expected_tool_not_called", "count" => 1, "scenario_keys" => [ "match_slots" ],
        "models" => [ "mock/alpha" ] },
      missing["evidence"]
    )

    suggested = needs.find { |need| need["tools"].include?("send_provider_reminder") }
    assert suggested, "no need carried the tool the judge suggested: #{needs.inspect}"
    assert_equal "tool", suggested["kind"]
    assert_nil suggested["server"]
    assert_equal "missing_capability", suggested.dig("evidence", "fault")

    instruction = needs.find { |need| need["kind"] == "instruction" }
    assert instruction, "no need came from the judge's instruction change: #{needs.inspect}"
    assert_equal "Change the agent's instructions", instruction["title"]
    assert_equal "Answer with the record count before any caveat.", instruction["detail"]
    assert_equal "instruction change", instruction.dig("evidence", "fault")
    assert_equal [ "tone" ], instruction.dig("evidence", "scenario_keys")
    assert_equal [ "mock/alpha" ], instruction.dig("evidence", "models")

    assert needs.all? { |need| need["evidence"].keys.sort == %w[count fault models scenario_keys] },
      "every need carries the same evidence keys: #{needs.map { |need| need['evidence'] }.inspect}"
  end

  test "limitations are what the agent gets wrong, never the capabilities it lacks" do
    agent = create_agent
    _evaluation, run = create_faulted_run(agent)

    limitations = brief_for(agent, evaluation_run: run).to_h["limitations"]

    tool_error = limitations.find { |item| item.dig("evidence", "fault") == "tool_error" }
    assert tool_error, "the erroring tool is a limitation: #{limitations.inspect}"
    assert_equal "fault", tool_error["kind"]
    assert_match(/find_records/, tool_error["title"])

    faults = limitations.map { |item| item.dig("evidence", "fault") }
    assert_includes faults, "low_quality"
    BRIEF::CAPABILITY_FAULTS.each do |fault|
      assert_not_includes faults, fault, "#{fault} is a need, not a limitation"
    end
  end

  # --- failing scenarios --------------------------------------------------

  test "every faulted scenario is listed with the model, fault, fix and tools it called" do
    agent = create_agent
    _evaluation, run = create_faulted_run(agent)

    rows = brief_for(agent, evaluation_run: run).to_h["failing_scenarios"]

    assert_equal %w[match_slots remind sync_health tone], rows.map { |row| row["key"] }
    assert_equal [ "alpha" ], rows.map { |row| row["model"] }.uniq
    assert_equal %w[expected_tool_not_called missing_capability tool_error low_quality], rows.map { |row| row["fault"] }
    assert rows.all? { |row| row["recommendation"].present? }, "each row says what would fix it"
    assert_equal [ "find_records" ], rows.find { |row| row["key"] == "sync_health" }["tools_called"]
    assert_equal "Find the next available slot", rows.first["prompt"]
  end

  test "the failing scenario list is capped so a whole suite cannot fill the brief" do
    agent = create_agent
    evaluation = agent.evaluations.new(name: "Wide suite", judge_kind: "rules", criteria: [])
    (BRIEF::MAX_FAILING_SCENARIOS + 5).times do |index|
      evaluation.scenarios.build(key: "s#{index}", prompt: "Question #{index}", position: index)
    end
    evaluation.save!
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    evaluation.scenarios.ordered.each do |scenario|
      run.scenario_results.create!(
        scenario: scenario, model: "alpha", provider: "mock", status: :failed, score: 0.1,
        fault: "low_quality", recommendation: "Say more.",
        diagnosis: { "fault" => "low_quality", "summary" => "Too short.", "recommendation" => "Say more." }
      )
    end

    rows = brief_for(agent, evaluation_run: run).to_h["failing_scenarios"]

    assert_equal BRIEF::MAX_FAILING_SCENARIOS, rows.size
  end

  # --- evaluation ---------------------------------------------------------

  test "the evaluation section carries the run, its pass rate, the per-model summary and the verdict" do
    agent = create_agent
    evaluation, run = create_faulted_run(agent)

    section = brief_for(agent, evaluation_run: run).to_h["evaluation"]

    assert_equal run.id, section["run_id"]
    assert_equal evaluation.id, section["id"]
    assert_equal "Scheduling catalog", section["name"]
    assert_equal "scenario", section["kind"]
    assert_equal 8, section["scenarios"]
    assert_equal 4, section["passed"]
    assert_equal 50.0, section["pass_rate"]
    assert_equal %w[mock/alpha mock/beta], section["models"].keys.sort
    assert_equal 100.0, section.dig("models", "mock/beta", "pass_rate")
    assert_equal "mock/beta", section.dig("verdict", "winner")
    assert_equal "pass rate", section.dig("verdict", "judge")
  end

  test "the most recent complete scenario run seeds the brief when none is named" do
    agent = create_agent
    _evaluation, run = create_faulted_run(agent)

    assert_equal run.id, brief_for(agent).to_h.dig("evaluation", "run_id")
  end

  # --- metrics ------------------------------------------------------------

  test "production traces become the metrics section, and a high error rate becomes a limitation" do
    agent = create_agent
    8.times { create_trace(agent_class: agent.telemetry_agent_class) }
    2.times { create_trace(agent_class: agent.telemetry_agent_class, status: "ERROR", error: "boom") }

    brief = brief_for(agent).to_h
    metrics = brief["metrics"]

    assert metrics, "traces for the agent's telemetry class produce a metrics section"
    assert_equal 10, metrics["requests"]
    assert_equal 2, metrics["errors"]
    assert_equal 20.0, metrics["error_rate"]
    assert_equal 300, metrics["p50_ms"]
    assert_equal 300, metrics["p95_ms"]
    assert_operator metrics["error_rate"], :>, BRIEF::ERROR_RATE_LIMIT

    reliability = brief["limitations"].find { |item| item["kind"] == "reliability" }
    assert reliability, "an error rate over the limit is worth telling the coding agent: #{brief['limitations'].inspect}"
    assert_match(/20.0% of production requests error/, reliability["title"])
  end

  test "a healthy error rate leaves the metrics in and the reliability limitation out" do
    agent = create_agent
    30.times { create_trace(agent_class: agent.telemetry_agent_class) }

    brief = brief_for(agent).to_h

    assert_equal 30, brief.dig("metrics", "requests")
    assert_equal 0.0, brief.dig("metrics", "error_rate")
    assert_nil brief["limitations"].find { |item| item["kind"] == "reliability" }
  end

  test "another agent's traces are not this agent's production signal" do
    agent = create_agent
    5.times { create_trace(agent_class: "SomebodyElseAgent") }

    assert_nil brief_for(agent).to_h["metrics"]
  end

  # --- an agent with nothing to go on -------------------------------------

  test "an agent with no evaluations still gets a brief that says so" do
    agent = create_agent

    brief = brief_for(agent)
    hash = brief.to_h

    assert_empty hash["needs"]
    assert_empty hash["failing_scenarios"]
    assert_nil hash["evaluation"]
    assert_equal "Scheduler", hash.dig("agent", "name")
    assert_equal [ "find_records" ], hash.dig("agent", "tools")
    assert_equal [ "sparkle" ], hash.dig("agent", "mcp_servers")
    assert_match(/Nothing: no evaluation run has found a capability gap/, brief.to_markdown)
  end

  # --- the coding agent's own credentials ---------------------------------

  test "credentials are reported by name, from the host's resolver, and never by value" do
    agent = create_agent
    ActionAgent.provider_credentials_resolver = lambda do |_owner, provider|
      provider == "anthropic" ? { access_token: "sk-ant-do-not-persist-me" } : {}
    end

    brief = brief_for(agent).to_h
    code_agent = brief["code_agent"]

    assert_equal "claude_code", code_agent["tool"]
    assert_equal [ "ANTHROPIC_API_KEY" ], code_agent["credentials_present"]
    assert_empty code_agent["credentials_missing"]
    assert_not_includes brief.to_json, "sk-ant-do-not-persist-me",
      "a credential VALUE must never reach the brief"
  end

  test "a credential nothing can satisfy is reported as the names that would satisfy it" do
    agent = create_agent

    code_agent = without_env("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN") do
      brief_for(agent).to_h["code_agent"]
    end

    assert_empty code_agent["credentials_present"]
    assert_equal [ %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN] ], code_agent["credentials_missing"]
    assert code_agent["needs"].any?, "the catalog entry says what the coding agent needs"
    assert code_agent["limitations"].any?
  end

  # --- the sandbox --------------------------------------------------------

  test "the sandbox constraints follow the network mode and the GitHub access the session was given" do
    agent = create_agent

    restricted = brief_for(agent, network_mode: "restricted", github_access: "none").to_h["sandbox"]
    read_only = brief_for(agent, network_mode: "allowlist", github_access: "read", repository: "acme/app").to_h["sandbox"]
    writable = brief_for(agent, network_mode: "open", github_access: "write", repository: "acme/app").to_h["sandbox"]

    assert_equal "mock", restricted["backend"]
    assert_equal "/workspace", restricted["workspace_path"]
    assert_includes restricted["constraints"].join(" "), "Network is restricted"
    assert_includes restricted["constraints"].join(" "),
      "No GitHub token: only public repositories can be cloned, and nothing can be pushed."

    assert_equal "/workspace/repo", read_only["workspace_path"]
    assert_equal "acme/app", read_only["repository"]
    assert_includes read_only["constraints"].join(" "), "Network is on an allowlist"
    assert_includes read_only["constraints"].join(" "),
      "GitHub access is read-only: clone and read, but pushing and opening pull requests will fail."

    assert_includes writable["constraints"].join(" "), "Network is open"
    assert_includes writable["constraints"].join(" "), "GitHub access is read-write"

    assert restricted["constraints"].any? { |line| line.include?("No host secrets are mounted") }
  end

  # --- the task -----------------------------------------------------------

  test "the default task scopes the work to the checkout and says what to do with the result" do
    agent = create_agent

    read_task = brief_for(agent, github_access: "read", repository: "acme/app").task
    write_task = brief_for(agent, github_access: "write", repository: "acme/app").task

    assert_match(%r{/workspace/repo}, read_task)
    assert_match(/Do not commit: this session has no write access/, read_task)

    assert_match(%r{/workspace/repo}, write_task)
    assert_match(/open a pull request/, write_task)
    assert_match(%r{branch named code-session/[0-9a-f]{8}}, write_task)
  end

  # The branch name is generated, so an unmemoized #task handed the JSON
  # brief, the rendered BRIEF.md and the session's own task column three
  # different branches to commit on.
  test "the task is the same every time it is read, branch name and all" do
    brief = brief_for(create_agent, github_access: "write", repository: "acme/app")

    assert_equal brief.task, brief.task
    assert_equal brief.task, brief.to_h["task"]
    assert_includes brief.to_markdown, brief.task
  end

  test "an operator's own task is used as written" do
    agent = create_agent

    assert_equal "Port the tool to the new API.", brief_for(agent, task: "Port the tool to the new API.").task
  end

  # --- markdown -----------------------------------------------------------

  HEADINGS = [
    "## Agent under improvement",
    "## What its evaluations say it needs",
    "## Failing scenarios",
    "## Your sandbox",
    "## Task"
  ].freeze

  test "the brief renders as the BRIEF.md a coding agent reads, and a persisted brief renders the same" do
    agent = create_agent
    _evaluation, run = create_faulted_run(agent)
    brief = brief_for(agent, evaluation_run: run, github_access: "write", repository: "acme/app")

    markdown = brief.to_markdown

    HEADINGS.each { |heading| assert_includes markdown, heading }
    assert_includes markdown, "# Brief for Claude Code"
    assert_includes markdown, brief.task
    assert_includes markdown, "browser_navigate"
    assert_includes markdown, "| match_slots |"

    # A brief compiled hours ago, read back from the row, writes the same file.
    stored = JSON.parse(brief.to_h.to_json)
    from_storage = BRIEF.markdown_for(stored)

    HEADINGS.each { |heading| assert_includes from_storage, heading }
    assert_equal markdown, from_storage
  end

  test "a stored brief with no task of its own falls back to the session's" do
    agent = create_agent
    session = ActionAgent::CodeSession.new(tool: "claude_code", backend: "mock", task: "Fix the sync tool.")

    markdown = BRIEF.markdown_for(brief_for(agent).to_h.except("task"), session: session)

    assert_includes markdown, "## Task"
    assert_includes markdown, "Fix the sync tool."
  end
end
