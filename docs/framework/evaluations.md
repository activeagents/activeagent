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
   fault counts; criterion statistics; faults grouped across scenarios; a
   verdict; Markdown or JSON (`Report`).

## Minimal example

```ruby
require "active_agent/evals"

scenarios = ActiveAgent::Evals::ScenarioParser.scenarios(<<~TEXT)
  # Orders
  Where is my order 4821? | tools: lookup_order
  Cancel my subscription | not_contains: I cannot
TEXT

models = ActiveAgent::Evals::ModelSpec.parse_all(%w[claude-sonnet-5 ollama/qwen3:8b], default_provider: "openai")

report = ActiveAgent::Evals::Runner.new(
  scenarios: scenarios,
  models: models,
  available_tools: { "lookup_order" => "Find an order by number" },
  instructions: SupportAgent.instructions,
  replay: ->(scenario, spec) { SupportAgent.evaluate(scenario.prompt, model: spec.model, provider: spec.provider) }
).call

puts report.to_markdown
```

`SupportAgent.evaluate` is whatever runs your agent and returns an
`ActiveAgent::Evals::Replay` (or a hash with the same keys). With ActiveAgent
that is a `prompt(...).generate_now` under `generate_with spec.provider,
model: spec.model`; with RubyLLM it is a chat with the model overridden; the
module does not care.

## Adding a judge

```ruby
judge = ActiveAgent::Evals::Judge.new(label: "claude-opus-5") do |instructions:, prompt:|
  JudgeAgent.with(instructions: instructions).prompt(message: prompt).generate_now.message.content
end

ActiveAgent::Evals::Runner.new(scenarios:, models:, replay:, judge: judge, instructions: SupportAgent.instructions).call
```

With a judge, every answer also gets a `task_completion` score (unless the
criteria already include an `llm_judge`), failing scenarios get a
judge-written recommendation with a suggested tool where one is missing, and
the verdict carries the judge's rationale. A judge that raises or answers
unusably is skipped for that call, so an evaluation never fails because the
judge did.

## Faults

| Fault | Meaning |
|---|---|
| `run_error` | The replay raised, or the agent returned nothing |
| `tool_error` | A tool the agent called returned an error |
| `missing_capability` | The agent said no tool covers the task |
| `expected_tool_not_called` | The scenario expects a tool the agent did not call |
| `forbidden_content` / `missing_content` | A content expectation failed |
| `low_quality` | The answer scored below the threshold (0.7) |

Assigned in that order, most mechanical cause first. `missing_capability`
and `expected_tool_not_called` are what turn a pasted list of *new* tasks into
a backlog: they say which tasks the current toolset cannot reach and, with a
judge, which tool to add.

## In a dashboard

`Runner#call` takes `on_result:` (each `Result` as it lands) and
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
| `ScenarioParser` | Pasted text or JSON → scenarios. Lines, `# Heading` groups, backticked prompts with notes, `\| tools: a, b \| contains: x` options |
| `Suite` | A YAML suite with groups; later documents override by key, so a deployment can add or reword tasks |
| `ModelSpec` | `provider/model` or a bare name with provider inference (`claude-*` → anthropic, `gpt-*` → openai, `name:tag` → ollama, `vendor/model` → openrouter) |
| `Replay` | What your agent produced: answer, tool calls, timing, tokens, cost, error |
| `Scorer` | Rule criteria (`response_present`, `min_length`, `max_latency_ms`, `token_budget`, `contains`, `not_contains`, `llm_judge`) plus the scenario's expectations |
| `Diagnosis` | One fault per failing result, with an evidence-based recommendation |
| `Judge` | Prompts and parsing for scoring, refining recommendations, and picking a winner; you supply the completion call |
| `Runner` | scenarios × models → `Result`s, calling your `replay` and the judge |
| `Report` | Per-model summary, criterion statistics, recommendations, verdict; Markdown / JSON |

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
