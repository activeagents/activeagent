---
title: Conversation Context
description: has_context persists prompts, responses and the full tool exchange to Active Record, and replays them on the next turn — with provenance and trace correlation on every row.
---
# {{ $frontmatter.title }}

`SolidAgent::HasContext` is the reason most apps reach for SolidAgent. It
gives an agent a conversation that outlives the request: prompts, replies
and the tool exchange in between are written to `agent_contexts`,
`agent_messages` and `agent_generations`, and read back on the next turn.

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

A context row is keyed by **contextable + agent class + action**, so each
action of each agent keeps its own thread per record.

## What gets written, and when

Nothing in the action above touches the database — the callbacks do, and
they run after the provider has answered:

1. `load_conversation` finds or creates the `AgentContext`.
2. The provider call happens.
3. The **last message of the prompt** is persisted as the user turn.
4. Any tool result messages in the response are persisted as `tool` rows.
5. The response is persisted: an `AgentGeneration` row with tokens, model,
   finish reason, duration, raw payload and provenance — plus the assistant
   message.

::: warning Don't write the user turn twice
With `auto_save` on (the default), step 3 stores the last prompt message
for you. Call `add_conversation_user_message` yourself only when you've
turned `auto_save: false` off, or the same turn lands in the table twice.
:::

## Naming the context

The name you pass decides what the generated methods are called. Pass
nothing and you get `context`, `load_context`, `context_messages`.

```ruby
has_context                              # context, load_context, add_user_message
has_context :conversation                # conversation, load_conversation, ...
has_context :research_session            # research_session, load_research_session, ...
```

| Method | Returns |
|--------|---------|
| `load_<name>(contextable:)` | Finds or creates the context for a record |
| `load_<name>(context_id:)` | Loads a specific context — how a second action joins an existing thread |
| `create_<name>(contextable:)` | Always creates a new one |
| `<name>_messages` | Message history as `{ role:, content: }` hashes, ready to pass to `prompt` |
| `add_<name>_user_message(content)` / `add_<name>_assistant_message(content)` | Append a turn by hand |
| `<name>_result` | Content of the last assistant message |
| `<name>_last_generation` | The last `AgentGeneration` row |
| `<name>_summary` | `{ id:, result:, message_count:, total_tokens:, created_at:, agent_name:, action_name: }` |

The unnamed forms (`context`, `load_context`, `context_messages`,
`context_result`, …) always delegate to the first context an agent
declares, so shared code in `ApplicationAgent` doesn't need to know the
name a subclass chose.

## Options

```ruby
has_context :session,
            class_name: "ChatSession",       # default: AgentContext, or {Name} for a named context
            message_class: "ChatMessage",    # inferred from class_name when omitted
            generation_class: "ChatGeneration",
            contextual: :chat_user,          # param key the context hangs off
            auto_save: false                 # stop persisting prompts and responses
```

**`contextual`** decides how the context appears:

| Value | Behaviour |
|-------|-----------|
| `:user`, `:document`, … | Auto-loads (or creates) from `params[:user]` after the prompt is built |
| `nil` (default) | Auto-creates a context with no contextable |
| `false` | No automatic context at all — you call `load_*` or `create_*` |

Auto-creation runs *after* the prompt is built, which is late for a
conversation that needs its history replayed. Call `load_*` explicitly in
the action when you're passing `<name>_messages` to `prompt`.

**`auto_save: false`** removes the persistence callbacks. You then own both
sides: `add_<name>_user_message` before the call, `add_<name>_assistant_message`
after. Useful when only some turns should be stored.

::: tip Anonymous classes can't have contexts
Contexts are persisted under `self.class.name`. A class built with
`Class.new(...)` has none, and creation fails the `agent_name` presence
validation — name the constant first.
:::

## Multiple contexts

An agent can keep more than one thread, each with its own subject:

```ruby
class MultiModalAgent < ApplicationAgent
  include SolidAgent::HasContext

  has_context :conversation, contextual: :user
  has_context :analysis, contextual: :document

  def analyze
    prompt message: params[:message]
  end
end
```

Both are created automatically. Only the first one gets the auto-save
callbacks — additional contexts are yours to write to, which is usually
what you want when the second one is a scratch pad rather than a
transcript.

## The tool exchange, not just the answer

Conversations that only store user and assistant text lose the interesting
half. When a response carries tool result messages, `HasContext` persists
each one as a `tool` row with its `tool_call_id`, name and result, deduped
by call id so re-persisting a shared message stack doesn't double up.

Executors that run tools themselves — a job, a platform's execution service
— know things the provider's response doesn't: the arguments that went in
and how long the call took. Override `tool_invocations` to hand them over:

```ruby
class ResearchAgent < ApplicationAgent
  include SolidAgent::HasContext

  has_context

  private

  def tool_invocations
    @tool_invocations ||= [] # [{ tool_call_id:, name:, arguments:, duration_ms: }, ...]
  end
end
```

Records match response messages by `tool_call_id`, or by position when the
provider didn't send one.

## Provenance and trace correlation

Every generation records **what produced it**, not just what came out:

```ruby
generation = context.generations.last
generation.provenance
# => { "agent_class" => "SupportAgent",
#      "agent_checksum" => "…",     # class-level prompt/embed options, minus credentials
#      "prompt_checksum" => "…",    # instructions, model, temperature, tool names
#      "context_checksum" => "…",   # context id, message count, last message id
#      "action_name" => "answer",
#      "trace_id" => "…",
#      "timestamp" => "2026-08-14T12:00:00Z",
#      "manifest_fingerprint" => "…" } # when built from a manifest
```

Checksums are what let you ask "did anything about this agent change
between these two runs?" without diffing prose.

Thread a distributed trace id through `prompt_options` and the context,
generation and your [telemetry](/framework/telemetry) trace all carry it:

```ruby
def answer
  prompt_options[:trace_id] = Current.trace_id

  load_conversation(contextable: params[:user])
  prompt messages: conversation_messages
end
```

```ruby
AgentContext.with_trace(trace_id)
AgentGeneration.with_trace(trace_id)
```

## Reading it back

The models are ordinary Active Record, scopes included:

```ruby
AgentContext.for_agent("SupportAgent").for_action("answer").recent.limit(10)
AgentContext.find_by(contextable: user).messages.chronological
AgentContext.find_by(contextable: user).total_tokens

AgentGeneration.by_model("gpt-4o-mini").with_tool_calls
AgentGeneration.recent.first.estimated_cost   # see Runs & cost
AgentMessage.tool_messages.where(tool_name: "fetch_url")
```

## Generators

```bash
# The tables and models
rails generate solid_agent:install

# An agent wired for context
rails generate solid_agent:agent Support --context --context_name conversation --contextual user

# Custom-named context models (ConversationContext, ConversationMessage, ...)
rails generate solid_agent:context conversation
```

## See also

- [Long-term memory](/solid_agent/memory) — what an agent should remember *across* conversations
- [Runs, cohorts and cost](/solid_agent/runs) — the execution record that sits above a context
- [Examples](/solid_agent/examples#persistent-conversation) — the full worked example
