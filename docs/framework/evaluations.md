# Evaluations

`ActiveAgent::Evals` is the evaluation core the dashboard's
[scenario evaluations](/framework/dashboard#scenario-evaluations) run on. It
ships inside the `activeagent` gem so any Rails app on ActiveAgent — and, with
one `require`, any app that calls models another way — can replay a list of
tasks across models, score the answers, and be told which tasks its agent
cannot do yet and why.

```ruby
require "active_agent/evals"   # loads on its own, without the rest of the framework
```

The module never talks to a model itself: you hand it one callable that runs
your agent, and optionally one that asks a judge model for a completion.

## What it does

1. **Scenarios** — a pasted list of user messages (`ScenarioParser`) or a YAML
   suite with groups (`Suite`). Each scenario can name the tools a passing
   answer should call and content it must or must not contain.
2. **Models** — candidate models to compare (`ModelSpec`), from
   `provider/model` or a bare name whose provider is inferred.
3. **Replay** — your callable runs the agent for each scenario × model and
   returns a `Replay`: answer, tool calls (with errors), timing, tokens, cost.
4. **Scoring** — rule criteria (`response_present`, `min_length`,
   `max_latency_ms`, `token_budget`, `contains`, `not_contains`, `llm_judge`)
   plus the scenario's expectations (`Scorer`).
5. **Diagnosis** — each shortfall gets exactly one fault and a recommendation
   (`Diagnosis`); a `Judge` can refine it with the tool to add or the
   instruction to change.
6. **Report** — per-model pass rate, mean score, latency, tokens, cost and
   fault counts; criterion statistics; faults grouped across scenarios into
   the fix each calls for; a verdict; Markdown, JSON or a self-contained
   HTML page (`Report`).

## Minimal example

```ruby
require "active_agent/evals"

scenarios = ActiveAgent::Evals::ScenarioParser.scenarios(<<~TEXT)
  # Orders
  Where is my order 4821? | tools: lookup_order
  Cancel my subscription | not_contains: I cannot
TEXT

models = ActiveAgent::Evals::ModelSpec.parse_all(%w[claude-sonnet-5 ollama/qwen3:8b], default_provider: "openai")
# The agent's system prompt, for the diagnosis and the judge — with
# ActiveAgent, the instructions template.
instructions = Rails.root.join("app/views/agents/support/instructions.md").read

report = ActiveAgent::Evals::Runner.new(
  scenarios: scenarios,
  models: models,
  available_tools: { "lookup_order" => "Find an order by number" },
  instructions: instructions,
  replay: ->(scenario, spec) { SupportAgent.evaluate(scenario.prompt, model: spec.model, provider: spec.provider) }
).call

puts report.to_markdown
File.write("eval-report.html", report.to_html)
```

The report renders three ways: `to_markdown` for terminals and PR comments,
`to_json` for machines, and `to_html(theme: nil)` — a self-contained page
(inline styles, no external assets) on the dashboard's design system that you
can archive next to a CI run or hand to a teammate, the way a test suite
publishes its report. It carries the same reading the dashboard's suite card
does: stat tiles, a panel per model with the judge's pick and the verdict,
the what-to-fix cards, the scenario × model matrix, and a disclosure per
scenario holding every answer. `theme:` is its only argument — `"light"` or
`"dark"` pins the palette, nil follows the viewer's system preference. It is
the same page the dashboard serves at
`/api/evaluations/:id/runs/:run_id/report`.

`SupportAgent.evaluate` is whatever runs your agent and returns an
`ActiveAgent::Evals::Replay` (or a hash with the same keys). With ActiveAgent
that is a `prompt(...).generate_now` under `generate_with spec.provider,
model: spec.model`; with RubyLLM it is a chat with the model overridden; the
module does not care.

## Adding a judge

```ruby
judge = ActiveAgent::Evals::Judge.new(label: "claude-opus-5") do |instructions:, prompt:|
  JudgeAgent.prompt(message: prompt, instructions: instructions).generate_now.message.content
end

ActiveAgent::Evals::Runner.new(scenarios:, models:, replay:, judge: judge, instructions: instructions).call
```

With a judge, every answer also gets a `task_completion` score (unless the
criteria already include an `llm_judge`), scenarios failing on
`missing_capability`, `expected_tool_not_called`, `ungrounded_answer`,
`missing_content` or `low_quality` get a judge-written recommendation with a suggested tool where
one is missing (`refine_faults:` and `judge_limit:`, 25 calls per run by
default, adjust that on `Runner.new`), and the verdict carries the judge's
rationale. A judge that raises or answers unusably is skipped for that call,
so an evaluation never fails because the judge did.

A scorable `task_completion` grade must independently meet the run's
`threshold` (0.7 by default). Successful tool and content checks cannot turn
a failing task-completion grade into a pass. `score` and `avg_score` remain
the aggregate across scored criteria; `avg_task_completion` in each model's
summary reports the judge's task-completion mean separately. Invalid judge
scores are unscorable, and unusable recommendation fields are discarded.

Hosts can correlate the replay and its judge calls with one trace context by
passing `around_evaluation:` to `Runner.new`. The callable receives the
scenario and model spec, yields the evaluation, and returns its result:

```ruby
around_evaluation = ->(scenario, spec, &evaluate) do
  TraceContext.with(scenario_key: scenario.key, model: spec.label) { evaluate.call }
end
```

The wrapper covers replay, scoring and recommendations. `on_result` runs
after the wrapper finishes; wrapper errors propagate. Direct
`Runner#evaluate` calls bypass the wrapper so a host doing its own scheduling
can establish context itself.

## Faults

| Fault | Meaning |
|---|---|
| `run_error` | The replay raised, or the agent returned nothing |
| `tool_error` | A tool the agent called returned an error |
| `missing_capability` | The agent said no tool covers the task |
| `expected_tool_not_called` | The scenario expects a tool the agent did not call |
| `ungrounded_answer` | The agent had tools, called none, and still stated specifics (a count, an id, a date) nothing supplied |
| `forbidden_content` / `missing_content` | A content expectation failed |
| `low_quality` | The answer scored below the threshold (0.7) |

Assigned in that order, most mechanical cause first. `missing_capability`
and `expected_tool_not_called` are what turn a pasted list of *new* tasks into
a backlog: they say which tasks the current toolset cannot reach and, with a
judge, which tool to add.

## What to fix

`Report#fix_items` is that backlog as data — one item per fault, in the same
order as `recommendations`, plus one per distinct instruction change the judge
proposed. Each names the scenarios and models it speaks for, the fix it calls
for, and the tools involved: the missing tools a scenario expected, the tools
that errored, or the tools the judge suggested adding, under a `tools_label`
that says which.

```ruby
report.fix_items.first
# => { "kind" => "fault", "fault" => "expected_tool_not_called", "count" => 3,
#      "scenario_keys" => [...], "models" => ["gpt-5-mini", "ollama/qwen3:8b"],
#      "recommendation" => "Enable search_slots for the agent…",
#      "quote" => nil, "tools_label" => "missing tools",
#      "tools" => [ { "name" => "search_slots", "note" => nil, "server" => {…} } ],
#      "server" => { "key" => "scheduling", "name" => "Scheduling", "status" => "available" },
#      "note" => nil,
#      "action" => { "label" => "Enable Scheduling for BookingAgent",
#                    "hint" => "MCP Services ->", "path" => "/mcp/scheduling" } }
```

Optional keywords on `Report.new` fill that in, and the HTML page renders
whatever they supply:

| Keyword | What it adds |
|---|---|
| `tool_resolver:` | A callable `name -> { "key", "name", "status" }` (`"enabled"`, `"available"` or `"unknown"`) naming the server behind a tool, so an item can say a tool exists but is not turned on |
| `agent_name:` | How an item names the agent (`"the agent"` by default) |
| `links:` | Route templates for the actions — `"mcp"` (`"/mcp/%{key}"`), `"tools"`, `"instructions"`. Without them an action still carries its label and hint, with `"path" => nil` |
| `verdict:` / `judge_label:` | A verdict already recorded for these results, so a report rebuilt from stored results shows the pick that run made rather than ranking them again |

Nothing here needs the dashboard: a CI job that hands `Report.new` a resolver
over its own MCP configuration gets the same cards in its HTML report, and
the same JSON to open issues from.

## In a dashboard

`Runner.new` takes `on_result:` (each `Result` as it lands) and
`Runner#evaluate(scenario, spec, replay)` scores a replay you already hold, so
a dashboard can run replays in background jobs and persist one row per
scenario × model. `Report#to_h` is JSON-ready. The ActionAgent engine's
`ScenarioEvaluationRunner` is the reference integration: it supplies the
replay (an `AgentRun` with a model override), prices tokens, wraps the owner's
judge credentials, and stores each result as an `EvaluationScenarioResult`.

## The pieces

| Class | Role |
|---|---|
| `Scenario` | One task: prompt, group, expected tools, content that must / must not appear, notes |
| `ScenarioParser` | Pasted text, JSON, or grouped YAML suites → scenarios. Lines, `# Heading` groups, backticked prompts with notes, `\| tools: a, b \| contains: x` options |
| `Suite` | A YAML suite with groups; later documents override by key, so a deployment can add or reword tasks |
| `ModelSpec` | `provider/model` or a bare name with provider inference (`claude-*` → anthropic, `gpt-*` → openai, `name:tag` → ollama, `vendor/model` → openrouter) |
| `Replay` | What your agent produced: answer, tool calls, timing, tokens, cost, error |
| `Scorer` | Rule criteria (`response_present`, `min_length`, `max_latency_ms`, `token_budget`, `contains`, `not_contains`, `llm_judge`) plus the scenario's expectations |
| `Diagnosis` | One fault per failing result, with an evidence-based recommendation |
| `Judge` | Prompts and parsing for scoring, refining recommendations, and picking a winner; you supply the completion call |
| `Runner` | scenarios × models → `Result`s, calling your `replay` and the judge |
| `Report` | Per-model summary, criterion statistics, recommendations, fix items, verdict; Markdown / JSON / HTML |

## Suites

```yaml
suite: support_bot
description: The questions the support team fields every week
groups:
  - key: orders
    name: Orders
    scenarios:
      - key: orders_1
        prompt: Where is my order?
        expect:
          tools: [lookup_order]
      - key: orders_2
        prompt: Cancel my subscription
        expect:
          not_contains: ["I cannot"]
        production_only: true   # needs data a local database does not have
```

```ruby
suite = ActiveAgent::Evals::Suite.load("config/evals/support_bot.yml", "config/evals/acme/support_bot.yml")
suite.scenarios(groups: %w[orders], include_production_only: false)
```

The same grouped document can be pasted into `ScenarioParser` as YAML or
JSON. It retains scenario keys, group keys and display names, expectations,
notes and production-only flags:

```ruby
scenarios = ActiveAgent::Evals::ScenarioParser.scenarios(
  File.read("config/evals/support_bot.yml"),
  include_production_only: false
)
```

The parser includes production-only scenarios by default for compatibility
with `Suite`; the dashboard's create and replace APIs exclude them by
default. Post the YAML/JSON document as `scenarios_text` and set
`include_production_only: true` alongside it to include those questions.
For creation both fields belong in `evaluation`; replacement accepts them
at the top level. Production selection happens during import: the dashboard
stores only the selected scenarios and their group keys, not the original
document, group display names, or environment flags. Re-import the source
document to change that selection. Invalid YAML or a selection containing
no scenarios returns an import error without creating a sampled evaluation.

## Running a host application's agent from the mounted dashboard

The engine normally replays scenarios with `ActionAgent::Agent#test_execute`.
A host with its own chat or agent runtime can opt individual evaluations
into an adapter without replacing the engine's catalog, selection, jobs,
result persistence, or report pages:

```ruby
ActionAgent.configure do |config|
  config.scenario_evaluation_adapter_resolver = ->(evaluation) do
    next unless evaluation.config["runtime"] == "host_support"

    ->(evaluation:, owner:, scenarios:, models:, on_result:) do
      HostSupportEvaluation.call(
        evaluation: evaluation, owner: owner, scenarios: scenarios,
        models: models, on_result: on_result
      )
    end
  end
end
```

The resolver receives the persisted evaluation and returns a callable or
`nil` for the engine's default runtime. The callable receives the engine's
resolved owner, already-selected core `Scenario` and `ModelSpec` objects,
and an `on_result` callback. It must return an `ActiveAgent::Evals::Report`
and call `on_result` once for every selected scenario/model result. Missing
or duplicate results fail the run instead of leaving a completed report
with missing rows. Exceptions also mark the run failed and retain results
already written.

The host owns provider execution, usage accounting, tool definitions, and
judge configuration. Use the supplied owner rather than a global current
user in background jobs; honor `evaluation.judge_kind`,
`evaluation.judge_model`, and the evaluation's tenant/role configuration.
The adapter path does not build the engine's judge or execute its agent.
It still passes through dashboard authentication, execution enablement,
and quota checks.

An observed agent can run a persisted evaluation only when its resolver
returns an adapter. Direct agent execution remains read-only. A host
catalog importer should register that evaluation without an immediate run,
then use the regular evaluation run endpoint.

Run metadata persists in the reserved `scores["_metadata"]` JSON key.
Per-result replay metadata persists in `diagnosis["_replay_metadata"]`,
is exposed separately as `metadata` in result API responses, and is restored
by `EvaluationRun#to_report`. Each result also records its evaluated scenario
in `diagnosis["_scenario_snapshot"]`; the public diagnosis excludes these
storage keys. Report reconstruction and the result matrix use that snapshot,
so refreshing a catalog cannot rewrite old questions, expectations, or notes.
The run records its judge label in `scores["_judge_label"]` as well. Legacy
results without snapshots remain readable using the current catalog.
This preserves host run/result IDs and response/judge trace IDs without a
schema migration. Existing result and report URLs continue to work:

- `<mount>/api/evaluations/:id/runs/:run_id` returns persisted result JSON.
- `<mount>/api/evaluations/:id/runs/:run_id/report` serves the HTML report.
- `<mount>/evaluations/:id/runs/:run_id/report` opens it within the dashboard.
- `<mount>/evaluations?evaluation=:id` opens a specific evaluation, including
  one outside the first index page. Add `&run=:run_id` to open its saved report.
