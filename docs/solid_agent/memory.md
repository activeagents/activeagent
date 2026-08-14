---
title: Long-Term Memory
description: has_memory gives agents save_memory and recall_memory tools over a durable note list scoped to a subject record — so agents hand work off to each other through shared memory.
---
# {{ $frontmatter.title }}

A [context](/solid_agent/context) is a transcript: everything that was
said, in order. Memory is the opposite — a short list of things worth
keeping, curated by the agent itself, that survives across conversations
and across agents.

`SolidAgent::HasMemory` gives the model two ordinary function-calling
tools, `save_memory` and `recall_memory`, and a place to put what it
writes.

```ruby
class ResearcherAgent < ApplicationAgent
  include SolidAgent::HasMemory

  has_memory

  def research
    prompt(
      message: "Research #{params[:project].name} and save what a writer would need to know.",
      tools: memory_tool_definitions
    )
  end

  def memory_subject
    params[:project]
  end
end
```

The model decides when to write and when to read. You decide what the
memory is *about*.

## Scoped to a subject, not to an agent

This is the design decision everything else follows from. Memory hangs off
a `(memorable, scope)` pair — any Active Record model plus a namespace
string — and **not** off the agent class. Every agent working on the same
subject sees the same notes.

That makes memory a hand-off channel:

```ruby
ResearcherAgent.with(project: project).research.generate_now
# ... later, a different agent, possibly a different request or deploy:
WriterAgent.with(project: project).draft.generate_now
```

`WriterAgent`'s `recall_memory` returns `ResearcherAgent`'s notes. Each
entry records the class that wrote it in `source_agent`, so provenance
survives the hand-off.

Scopes keep unrelated streams apart on the same subject:

```ruby
has_memory scope: "competitive_research", class_name: "AgentMemory"
```

## Choosing the subject

`memory_subject` defaults to `params[:memorable]`, falling back to the
`HasContext` contextable when the agent has one. Override it when the
subject lives somewhere else:

```ruby
def memory_subject
  params[:project]
end
```

Without a subject, `memory` is `nil` and both tools return
`{ error: "No memory subject available" }` rather than raising — the model
gets a legible answer and carries on.

## The two tools

`memory_tool_definitions` returns the schemas to hand to `prompt`:

| Tool | Arguments | Does |
|------|-----------|------|
| `save_memory` | `content:` (required), `category:` | Appends a note, tagged with the calling agent class |
| `recall_memory` | `category:`, `limit:` (default 20) | Returns notes, newest first, optionally filtered |

The same contract is available module-level, for executors that aren't
agents — a platform service, an MCP server:

```ruby
SolidAgent::HasMemory.tool_definitions.map { |t| t[:name] }
# => ["save_memory", "recall_memory"]
```

## Priming instead of recalling

A recall costs a round trip, and the model has to remember to ask. When you
know the notes are relevant, put them in the instructions instead:

```ruby
def draft
  prompt(
    instructions: [ "You are a product writer.", memory&.to_prompt ].compact.join("\n\n"),
    message: "Draft the launch post for #{params[:project].name}.",
    tools: memory_tool_definitions
  )
end
```

`to_prompt` renders the notes as a labelled list with each note's source
agent, and returns an empty string when there's nothing to say.

## Working with memory directly

The generated `AgentMemory` and `AgentMemoryEntry` are plain models:

```ruby
memory = AgentMemory.for(project)                      # find or create
memory = AgentMemory.for(project, scope: "planning")

memory.remember("Ships on the 14th", source_agent: "ResearcherAgent", category: "fact")
memory.recall(limit: 5, category: "handoff")           # newest first
memory.summary_list                                    # contents, oldest first
memory.to_prompt                                       # formatted for instructions
memory.forget(entry_id)
```

Nothing is append-only by force. Notes go stale, and pruning them is
ordinary Active Record:

```ruby
memory.entries.where(category: "task").where(created_at: ..1.month.ago).find_each(&:destroy)
```

## Keeping memory useful

- **Categories earn their keep at recall time.** `fact`, `task`, `handoff`
  are the ones that tend to survive contact with real use; anything finer
  usually goes unused.
- **Say what to save in the instructions.** The tool description tells the
  model memory exists; your instructions tell it what's worth keeping.
- **Memory is model-authored text about your users' data.** It's readable
  by every agent on that subject — scope it deliberately, and prune it.

## See also

- [Conversation context](/solid_agent/context) — the transcript memory summarizes
- [Examples](/solid_agent/examples#memory-hand-off) — the worked hand-off
