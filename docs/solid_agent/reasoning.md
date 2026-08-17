---
title: Reasoning
description: Collect extended-thinking output from models that expose it, and persist it on generation records with HasReasons and Reasonable.
---
# {{ $frontmatter.title }}

Models that support extended thinking — Claude's thinking blocks, OpenAI's
reasoning models — return their working alongside the answer, and bill for
it separately. SolidAgent gives you somewhere to put it: `HasReasons` on
the agent collects it, `Reasonable` on a model persists it.

## Capturing on the agent

```ruby
class AnalysisAgent < ApplicationAgent
  include SolidAgent::HasContext
  include SolidAgent::HasReasons

  generate_with :anthropic, model: "claude-sonnet-5"

  # Declared before has_context so this wrapper is the outer one: by the
  # time it runs, HasContext has written the generation row that
  # `persist: true` updates.
  around_generation :capture_generation_reasoning

  has_context contextual: :document
  has_reasons persist: true, budget_tokens: 10_000

  def analyze
    prompt message: params[:question], **reasoning_prompt_options
  end

  private

  def capture_generation_reasoning
    response = yield
    capture_reasoning(response)
    response
  end
end
```

Two moving parts:

- **`reasoning_prompt_options`** turns the `has_reasons` configuration into
  prompt options — `extended_thinking: true` when `auto_capture` is on, and
  `reasoning_budget_tokens` when a budget is set.
- **`capture_reasoning(response)`** reads the reasoning off the response and
  records it. Reasoning only exists once the provider has answered, so hand
  it the response from a callback (as above) or wherever you have it.

### `has_reasons` options

| Option | Default | Does |
|--------|---------|------|
| `auto_capture` | `true` | Ask for extended thinking in `reasoning_prompt_options` |
| `persist` | `false` | Write captured reasoning onto the latest generation record |
| `budget_tokens` | `nil` | Default thinking budget |
| `redact_on_persist` | `false` | Store `"[Redacted]"` and the token count, not the text |

### Reading what was captured

Inside the agent instance that ran:

```ruby
reasons                 # => [SolidAgent::Reasonable::Reason, ...]
last_reasoning&.content
total_reasoning_tokens
has_reasoning?
reasoning_chain         # every non-redacted reason, joined
reasoning_stats
# => { count: 2, total_tokens: 450, total_thinking_time_ms: 1200,
#      redacted_count: 0, models: ["claude-sonnet-5"] }

add_reason(content: "Chose the strict parser", tokens: 0)  # your own note
clear_reasons!
```

These live on the instance, so they're reachable from actions and callbacks
— not from the console after the fact. That's what persistence is for.

## Persisting on the model

`persist: true` needs a generation model that can hold reasoning. The
generator adds the columns and the concern:

```bash
rails generate solid_agent:reasons AgentGeneration
rails db:migrate
```

```ruby
class AgentGeneration < ApplicationRecord
  include SolidAgent::Reasonable
end
```

```ruby
generation = AgentGeneration.recent.first
generation.reasoning_content
generation.reasoning_tokens
generation.reasoning_metadata
generation.has_reasoning?
generation.reasoning_redacted?
generation.reasoning_summary(length: 120)
generation.to_reason              # back to a Reason object

generation.store_reasoning!(response)   # extract from a provider response
generation.store_reason!(reason)        # store one you already have
```

Any model can take reasoning, under whatever column names you already have:

```bash
rails generate solid_agent:reasons MyGeneration \
  --content_column thinking_trace --tokens_column think_tokens
```

```ruby
class MyGeneration < ApplicationRecord
  include SolidAgent::Reasonable

  reasonable_config column: :thinking_trace, tokens_column: :think_tokens
end
```

## Reasoning tokens are billed tokens

`AgentGeneration` records `reasoning_tokens` separately from output tokens,
and `thinking?` tells you a generation used extended thinking at all. Both
feed [cost estimation](/solid_agent/runs#cost) — a thinking-heavy agent can
cost several times what its visible output suggests, and this is where that
shows up.

## Handle it like user data

Reasoning is model-generated text about your users' data, produced without
the editorial pass the answer gets. It can restate inputs verbatim, and it
can be wrong in ways the answer isn't.

- `redact_on_persist: true` keeps the token accounting and drops the text.
- Reasoning is a record of what the model considered, not an explanation
  you can rely on being faithful.
- If a conversation is user-visible, decide deliberately whether the
  thinking is too.

## See also

- [Anthropic provider](/providers/anthropic) — enabling extended thinking
- [Usage statistics](/actions/usage) — where reasoning tokens land in usage
- [Runs, cohorts and cost](/solid_agent/runs) — what thinking costs
- [Examples](/solid_agent/examples#reasoning) — the worked example
