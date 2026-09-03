# ActiveAgents Evals

Scenario evaluations for AI agents that answer with tools: replay a list of
tasks across models, score the answers, diagnose the faults, and get told what
to fix.

The gem is framework-agnostic. It knows nothing about how your agent runs —
ActiveAgent, RubyLLM, LangChain over HTTP, a shell script — only how to turn a
pasted list of user messages into scenarios, how to score what came back, and
how to explain a failure. It is the evaluation core behind the
[ActionAgent dashboard](https://docs.activeagents.ai/framework/dashboard)'s
scenario evaluations and behind Sparkle's Clara evaluation suite, and it is
released separately so any dashboard can offer the same thing.

## Install

```ruby
# Gemfile
gem "activeagents-evals"
```

Nothing beyond `activesupport`'s core extensions is loaded.

## Sixty-second tour

```ruby
require "activeagents/evals"

# 1. Scenarios — paste a list, load a YAML suite, or build them by hand.
scenarios = ActiveAgents::Evals::ScenarioParser.scenarios(<<~TEXT)
  # Find records
  Which gynecologists in Charlotte have scheduling enabled? | tools: find_records
  Show me all providers with no license on file
  # Blame
  Who changed the biography for Dr. AbdelRazek? | contains: AbdelRazek
TEXT

# 2. Models — a frontier model against the latest open-weights model.
models = ActiveAgents::Evals::ModelSpec.parse_all(%w[claude-sonnet-5 ollama/qwen3:8b], default_provider: "openai")

# 3. A judge (optional): any callable that returns a completion.
judge = ActiveAgents::Evals::Judge.new(label: "claude-opus-5") do |instructions:, prompt:|
  RubyLLM.chat(model: "claude-opus-5").with_instructions(instructions).ask(prompt).content
end

# 4. Run — you supply the one callable that talks to your agent.
report = ActiveAgents::Evals::Runner.new(
  scenarios: scenarios,
  models: models,
  judge: judge,
  instructions: MyAgent.instructions,
  available_tools: MyAgent.tools.to_h { |tool| [tool.name, tool.description] },
  replay: lambda do |scenario, spec|
    turn = MyAgent.run(scenario.prompt, model: spec.model, provider: spec.provider)
    ActiveAgents::Evals::Replay.new(
      answer: turn.answer,
      tool_calls: turn.tool_calls.map { |call| { "name" => call.name, "arguments" => call.arguments, "error" => call.failed? } },
      duration_ms: turn.duration_ms,
      input_tokens: turn.input_tokens,
      output_tokens: turn.output_tokens
    )
  end
).call

puts report.to_markdown        # per-model summary, scenario × model matrix, recommendations, answers
report.to_h                    # the same, for your own UI
report.summary_by_model        # pass rate, mean score, latency, tokens, cost, fault counts per model
report.recommendations         # faults grouped across scenarios, with the fix each calls for
report.verdict                 # { "winner", "rationale", "judge" }
```

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

## Faults

A result passes when the replay completed, met the scenario's expectations, and
its mean score reached the threshold (0.7). Anything else carries exactly one
fault, assigned from the evidence in this order:

| Fault | Meaning | Typical fix |
|---|---|---|
| `run_error` | The replay raised, or the agent returned nothing | Credentials, model name, throttling |
| `tool_error` | A tool the agent called returned an error | Fix the tool, or its parameter descriptions |
| `missing_capability` | The agent said no tool covers the task | Add the tool the recommendation names |
| `expected_tool_not_called` | The scenario expects a tool the agent did not call | Enable the tool, or sharpen its description / the instructions |
| `forbidden_content` / `missing_content` | A content expectation failed | Instructions, or the tool's output |
| `low_quality` | The answer scored below the threshold | Read it against the weakest criterion |

`missing_capability` and `expected_tool_not_called` are what turn a pasted list
of *new* tasks into a backlog: they say which tasks the current toolset cannot
reach and, with a judge, which tool to add.

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
suite = ActiveAgents::Evals::Suite.load("config/evals/support_bot.yml", "config/evals/acme/support_bot.yml")
suite.scenarios(groups: %w[orders], include_production_only: false)
```

## Persisting results

`Runner#call` takes `on_result:`, called with each `Result` as it lands, and
`Runner#evaluate(scenario, spec, replay)` scores a replay you already have —
so a dashboard can run replays in background jobs and write one row per
scenario × model. `Result#to_h` and `Report#to_h` are plain, JSON-ready
hashes. The ActionAgent engine's `EvaluationScenarioResult` is one such store.

## Development

```sh
cd evals && ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require File.expand_path(f) }'
```

The gem is released from the [activeagent](https://github.com/activeagents/activeagent)
repository alongside `activeagent` and `actionagent`.
