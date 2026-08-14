---
title: SolidAgent
description: Database-backed persistence for ActiveAgent — conversations, generations, the tool stream, long-term memory, runs and cost — as Active Record models you own.
---
# {{ $frontmatter.title }}

ActiveAgent runs agents; it deliberately doesn't store anything. No Active
Record, no tables, no migrations — a generation happens and the response is
yours to do something with.

[SolidAgent](https://github.com/activeagents/solid_agent) is the gem that
remembers. It adds database-backed persistence for everything an agent
does: the conversation and its full tool/MCP exchange, every generation
with tokens and provenance, agent-curated long-term memory, reasoning
traces, durable run records, and cost estimates on top of the token counts.

It is a separate gem because persistence is a real dependency — installing
`activeagent` shouldn't drag in Active Record for apps that never need it.
`solid_agent` depends on `activeagent`, never the other way round.

```ruby
# Gemfile
gem "activeagent"
gem "solid_agent"
```

```bash
bundle install
rails generate solid_agent:install
rails db:migrate
```

::: tip Already running the dashboard?
The [dashboard engine](/framework/dashboard) (`actionagent`) depends on
`solid_agent` and installs its own copy of this schema, prefixed and
namespaced under `ActionAgent::`. Your app's own agents still want the
generator above — the two sets of tables are independent.
:::

## What the generator installs

Migrations and models, into `app/models/`, where they're yours to edit.
SolidAgent's concerns talk to them through a duck-typed contract, so
renaming a class or adding columns is a supported thing to do rather than a
fork.

| Model | Holds |
|-------|-------|
| `AgentContext` | One conversation or task session: agent, action, the record it's about, instructions, cumulative tokens, `trace_id` |
| `AgentMessage` | Every turn — user, assistant, system and tool — with tool call ids, arguments, results, attachments and a content checksum |
| `AgentGeneration` | One provider call: content, model, finish reason, input/output/cached/reasoning tokens, duration, raw payload, provenance |
| `AgentMemory` / `AgentMemoryEntry` | Agent-curated notes about a subject record, with `source_agent` provenance |
| `AgentRun` | One execution: lifecycle status, input, output, an append-only progress stream, and an instructions fingerprint |

## The concerns

Include what you need; nothing is all-or-nothing.

| Concern | Adds |
|---------|------|
| [`HasContext`](/solid_agent/context) | `has_context` — persists prompts, responses and the tool stream, and replays them on the next turn |
| [`HasMemory`](/solid_agent/memory) | `has_memory` — `save_memory` / `recall_memory` tools the model calls, scoped to a subject so agents hand off through it |
| [`HasTools`](/solid_agent/tools) | `has_tools` / `tool` — tool schemas from JSON view templates or an inline DSL |
| [`StreamsToolUpdates`](/solid_agent/tools#live-tool-status) | `tool_description` — broadcasts "what is it doing" over ActionCable while tools run |
| [`HasReasons`](/solid_agent/reasoning) | `has_reasons` — collects extended-thinking output; `Reasonable` persists it on generation records |

And three things that are useful without an agent at all:

| Module | Does |
|--------|------|
| [`ToolCache`](/solid_agent/tools#caching-tool-results) | Caches tool/MCP results by `(tool, normalized args)` with a TTL |
| [`ModelPricing`](/solid_agent/runs#cost) | Turns token counts into estimated USD |
| [`AgentManifest`](/solid_agent/manifests) | Reads, validates, converts and builds agents from portable `.agent.md`, Dotprompt and CrewAI files |

## The shortest useful example

```ruby
class SupportAgent < ApplicationAgent
  include SolidAgent::HasContext

  has_context :conversation, contextual: :user

  def answer
    load_conversation(contextable: params[:user])

    prompt messages: conversation_messages + [
      { role: "user", content: params[:message] }
    ]
  end
end
```

```ruby
SupportAgent.with(user: user, message: "My invoice is wrong").answer.generate_now
SupportAgent.with(user: user, message: "It's the VAT line").answer.generate_now

AgentContext.for_agent("SupportAgent").find_by(contextable: user)
  .messages.chronological.map { |m| [ m.role, m.content ] }
# => [["user", "My invoice is wrong"], ["assistant", "..."],
#     ["user", "It's the VAT line"],  ["assistant", "..."]]
```

Two requests, four rows, no session state — and the second request knew
about the first because it read the table, not a cache.

## Where to go next

- **[Conversation context](/solid_agent/context)** — `has_context` in full: naming, multiple contexts, the tool stream, provenance and trace correlation
- **[Long-term memory](/solid_agent/memory)** — notes an agent curates itself, and hand-offs between agents
- **[Tools, streaming and caching](/solid_agent/tools)** — schemas, live status, cached results
- **[Reasoning](/solid_agent/reasoning)** — capturing and persisting extended thinking
- **[Runs, cohorts and cost](/solid_agent/runs)** — durable run records, progress events, instruction cohorts, spend
- **[Agent manifests](/solid_agent/manifests)** — agents defined in files, portable across frameworks
- **[Examples](/solid_agent/examples)** — a worked example per concern

## Related

- [Dev Console (Dashboard Engine)](/framework/dashboard) — reads this schema and renders it
- [Telemetry](/framework/telemetry) — the `trace_id` that joins generations to traces
- [Tools](/actions/tools) — the framework's own tool calling, which `HasTools` writes schemas for
- [solid_agent on GitHub](https://github.com/activeagents/solid_agent)
