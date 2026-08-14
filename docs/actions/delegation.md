---
title: Delegation
description: Agent-as-tool delegation. Hand part of a job to another agent with a declared schema, a cost and latency budget, and a swappable backend.
---
# {{ $frontmatter.title }}

A [tool](/actions/tools) is a Ruby method your model can call. A **delegation** is another agent your model can call.

Same mechanism, different unit of work: the callee has its own instructions, its own templates, its own model, and its own budget. That separation is the whole point. A specialist agent stays specialist, and the generalist orchestrating it never inherits its prompt.

## Quick Start

Declare what the sub-agent exposes, then delegate to it:

::: code-group
<<< @/../test/docs/actions/delegation_examples_test.rb#classifier_agent {ruby:line-numbers} [The sub-agent]
<<< @/../test/docs/actions/delegation_examples_test.rb#triage_agent {ruby:line-numbers} [The caller]
:::

`delegate_to` turns every contract the sub-agent declares into a tool. Nothing else changes: the delegated tools sit alongside the action's own `tools:`, and the provider routes calls to them exactly as it routes any other tool call.

## Three Declarations, Three Owners

Delegation has three moving parts, and each is declared where the knowledge actually lives:

| Part | Declared on | Why there |
|:-----|:------------|:----------|
| **The contract** — inputs, outputs, description | the sub-agent | It changes when the action changes. Callers never restate it. |
| **The budget** — calls, tokens, cost, latency | the call site | Only the caller knows what the work is worth. |
| **The backend** — provider, model, sampling | the call site | The same sub-agent is worth different silicon in different parents. |

## Contracts

`delegation` declares one action: what it accepts, and optionally what it returns.

```ruby
class TranslatorAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini"

  delegation :translate, description: "Translate text into a target language" do
    string :text, required: true, description: "Text to translate"
    string :locale, required: true, description: "BCP 47 target locale, e.g. pt-BR"
  end

  def translate(text:, locale:)
    prompt(message: "Translate into #{locale}:\n\n#{text}")
  end
end
```

The `description` is the only thing a calling model reads before deciding whether to hand work over. Write it for someone who has never seen the code.

### Schema DSL

Inside a `delegation` block:

```ruby
delegation :search, description: "Search the product catalogue" do
  string  :query, required: true, description: "What the customer is looking for"
  integer :limit, description: "Maximum results (default 10)"
  number  :max_price, description: "Upper price bound in USD"
  boolean :in_stock_only
  string  :sort, enum: %w[relevance price rating], description: "Result ordering"

  array :categories, of: :string, description: "Restrict to these categories"

  array :filters do              # array of objects
    string :field, required: true
    string :value, required: true
  end

  object :shipping do            # nested object
    string :country, required: true, description: "ISO 3166-1 alpha-2"
  end
end
```

Every keyword you pass beyond `required:` and `description:` lands in the JSON Schema verbatim, so `enum`, `format`, `minimum`, `pattern` and friends all work.

### Reusing an existing schema

A contract can take a JSON Schema hash, or any class that responds to `to_json_schema` — which includes anything using [`ActiveAgent::SchemaGenerator`](/actions/structured_output):

```ruby
delegation :create, description: "Draft a support ticket", schema: TicketForm
delegation :notify, description: "Send a notification", schema: {
  type: "object",
  properties: { channel: { type: "string" } },
  required: [ "channel" ]
}
```

### Declared outputs

`returns` declares the shape the action answers with. ActiveAgent turns it into the sub-agent's `response_format`, parses the answer, and checks the required keys before handing it back — so the calling agent receives data, not a blob of text it has to re-parse.

```ruby
delegation :classify, description: "Classify a support ticket by topic and urgency" do
  string :body, required: true, description: "The customer's message, verbatim"

  returns do
    string :category, required: true, enum: %w[billing bug account other]
    string :urgency, required: true, enum: %w[low normal high]
  end
end
```

The delegated call now returns `{ category: "billing", urgency: "high" }`.

When the model returns something that misses a required key, the caller gets a structured `invalid_result` it can act on rather than an exception:

```ruby
{ error: "invalid_result", missing: [ "urgency" ], message: "...", content: "..." }
```

Pass `on_invalid: :raise` to the contract if you would rather the generation fail loudly.

### Delegating to an agent you do not own

Declare the contract at the call site instead:

```ruby
delegate_to Vendor::ClassifierAgent, action: :classify,
            description: "Classify a support ticket" do
  string :body, required: true, description: "Ticket body"
end
```

## Budgets

A sub-agent is a loop inside a loop. The parent model decides how often to call it, and each call spends tokens and wall-clock time nobody explicitly authorized. A budget puts a ceiling on that.

```ruby
delegation_budget max_calls: 6, max_duration: 45          # every delegation, together

delegate_to TicketClassifierAgent, budget: { max_calls: 1, timeout: 10 }
delegate_to KnowledgeBaseAgent, budget: { max_calls: 3, max_tokens: 20_000 }
```

Both apply — a call has to clear the agent-wide ceiling *and* its own limit.

<!-- @include: @/parts/examples/delegation-examples-test.rb-test-budgets-layer:-the-agent-wide-ceiling-and-the-per-delegation-limit.md -->

| Limit | Unit | Meaning |
|:------|:-----|:--------|
| `max_calls` | count | Delegated invocations |
| `max_tokens` | tokens | Cumulative tokens the sub-agent spent |
| `max_cost` | USD | Cumulative spend — needs [rates](#cost-budgets) |
| `max_duration` | seconds | Cumulative wall-clock across delegated calls |
| `timeout` | seconds | Wall-clock ceiling for a **single** call |
| `on_exceeded` | `:stop` / `:raise` | What happens at the ceiling |
| `rates` | hash | Inline token prices for `max_cost` |

Budgets are scoped to one generation. The ledger lives on the agent instance, which ActiveAgent creates fresh for every generation, so there is nothing to reset and no cross-request bleed.

### Exhausting a budget

By default (`on_exceeded: :stop`), the delegation stops and the calling model is told why, in terms it can act on:

<!-- @include: @/parts/examples/delegation-examples-test.rb-test-an-exhausted-budget-answers-the-model-instead-of-raising-at-it.md -->

The generation keeps going and the model answers with what it already has. That is almost always what you want: a bounded answer beats a raised exception halfway through a conversation.

When you would rather fail loudly, `on_exceeded: :raise` raises `ActiveAgent::Delegation::BudgetExceededError`, which carries the violated limit:

```ruby
delegate_to KnowledgeBaseAgent, budget: { max_calls: 3, on_exceeded: :raise }

rescue ActiveAgent::Delegation::BudgetExceededError => error
  error.violation.limit    #=> :max_calls
  error.violation.allowed  #=> 3
  error.violation.used     #=> 3
```

Since token spend can only be measured after a call, limits are checked *before* each call: `max_tokens: 8_000` means "stop delegating once 8,000 tokens have been spent", not "never exceed 8,000 tokens".

### Cost budgets

ActiveAgent ships no built-in price list — vendor pricing moves faster than gem releases, and a stale table silently under-reports spend. Register the rates you actually pay, in USD per one million tokens:

```ruby
# config/initializers/active_agent.rb
ActiveAgent::Delegation::Pricing.register("gpt-4o-mini", input: 0.15, output: 0.60)
ActiveAgent::Delegation::Pricing.register(/\Aclaude-haiku/, input: 1.00, output: 5.00)
```

String patterns match by prefix, so `"gpt-4o-mini"` also covers `"gpt-4o-mini-2024-07-18"`. Or state rates on a single budget:

```ruby
delegate_to SummarizerAgent, budget: { max_cost: 0.05, rates: { input: 0.15, output: 0.60 } }
```

A model with no known rates contributes `0.0` to the cost ledger rather than a guess, so `max_cost` never fires on invented numbers.

### Inspecting spend

Every ledger is readable after a generation:

```ruby
agent = TriageAgent.new
agent.process(:triage, ticket: ticket)
agent.process_prompt

agent.delegation_ledger.to_h                #=> { calls: 3, tokens: 4_120, cost: 0.0009, duration: 5.2 }
agent.delegation_ledger_for(:classify).to_h #=> { calls: 1, tokens: 380, cost: 0.0001, duration: 0.7 }
```

## Swappable Backends

A sub-agent's contract is separate from what serves it. The same agent can run on a small local model inside one parent and a frontier model inside another — and neither agent's code changes when you move it.

<<< @/../test/docs/actions/delegation_examples_test.rb#backend_swap {ruby:line-numbers}

```ruby
delegate_to SummarizerAgent, backend: { model: "gpt-4o-mini", temperature: 0 }  # same provider
delegate_to SummarizerAgent, backend: :ollama                                   # different provider
delegate_to SummarizerAgent, backend: { provider: :anthropic, model: "claude-haiku-4-5" }
```

Changing the provider rebuilds provider configuration — host, credentials, service — rather than merging a hash over the old one, so nothing leaks between vendors. Template lookup still resolves to the original agent's views.

Backend options are applied after the sub-agent's own action runs, so the call site wins. That matches ActiveAgent's precedence everywhere else: **runtime > agent class > `config/active_agent.yml`**.

## Scoping Delegations Per Action

By default every declared delegation is offered on every action. Narrow it with the `delegations:` prompt option:

```ruby
def triage(ticket:)
  prompt(message: ticket)                                 # every delegation
end

def acknowledge(ticket:)
  prompt(message: ticket, delegations: false)             # none — just answer
end

def route(ticket:)
  prompt(message: ticket, delegations: [ :classify ])     # one
end
```

## Testing Delegations

Two properties make delegations easy to test.

**They are ordinary methods.** `delegate_to` defines a real instance method, so you can call one directly with no model in the loop:

<<< @/../test/docs/actions/delegation_examples_test.rb#testing_call {ruby:line-numbers}

**The backend is swappable.** Point a sub-agent at the [Mock provider](/providers/mock) in tests and the contract stays exactly as production has it:

<<< @/../test/docs/actions/delegation_examples_test.rb#testing_backend {ruby:line-numbers}

<!-- @include: @/parts/examples/delegation-examples-test.rb-test-a-delegation-is-an-ordinary-method,-so-tests-can-call-it-without-a-model.md -->

And what the calling model actually sees is plain data you can assert on:

<!-- @include: @/parts/examples/delegation-examples-test.rb-test-the-sub-agents'-declared-schemas-are-what-the-triage-model-sees.md -->

## Instrumentation

Every delegated call emits `delegate.active_agent` with the agent, sub-agent, action, tool name, arguments, resolved model, duration, usage, cost and the running ledger. Refusals emit `delegation_refused.active_agent` with the violated limit.

```ruby
ActiveSupport::Notifications.subscribe("delegate.active_agent") do |*, payload|
  Rails.logger.info(
    "#{payload[:agent]} → #{payload[:delegate]}##{payload[:action]} " \
    "#{payload[:duration_ms]}ms #{payload[:usage]&.total_tokens} tokens"
  )
end
```

See [Instrumentation](/framework/instrumentation) for the full event catalogue.

## Provider Support

Delegation is built on function calling, so it works wherever [tools](/actions/tools#provider-support-matrix) do. Declared `returns` schemas additionally use [structured output](/actions/structured_output#provider-support), which is better supported on some providers than others — a contract whose provider ignores `response_format` still validates the parsed answer and reports `invalid_result` when it does not fit.

## Reference

### `delegation`

| Option | Type | Purpose |
|:-------|:-----|:--------|
| `description:` | String | **Required.** What the action does, for the calling model |
| `schema:` | Hash, Class, Schema | Inputs, when not using the block DSL |
| `returns:` | Hash, Class, Schema | Declared output shape |
| `budget:` | Hash | Default budget callers inherit |
| `on_invalid:` | `:error` / `:raise` | When output misses required keys |

### `delegate_to`

| Option | Type | Purpose |
|:-------|:-----|:--------|
| `only:` / `except:` | Symbol, Array | Which of the sub-agent's contracts to expose |
| `as:` | Symbol | Rename the tool the model sees |
| `action:` | Symbol | Declare a contract here instead of on the sub-agent |
| `description:` / `schema:` / `returns:` | — | Inline contract, used with `action:` |
| `backend:` | Symbol, Hash | Provider and options this delegation runs on |
| `budget:` | Hash | Limits for this delegation |
| `params:` | Hash, Symbol, Proc | Params forwarded to the sub-agent |

`params:` accepts a Hash, the name of a method on the delegating agent, or a Proc evaluated against it:

```ruby
delegate_to KnowledgeBaseAgent, params: { locale: "en" }
delegate_to KnowledgeBaseAgent, params: :knowledge_base_params
delegate_to KnowledgeBaseAgent, params: -> { { account_id: params[:account_id] } }
```

## Troubleshooting

**The model never delegates.** The description is the only thing it reads. Say what the sub-agent does and when to use it, not what it is. `tool_choice: "required"` forces a hand-off.

**`already responds to #name`.** The tool name collides with an existing method on the delegating agent. Rename it with `as:`.

**`does not declare any delegations`.** The sub-agent has no `delegation` macro. Add one to it, or declare the contract at the call site with `action:`.

**Arguments the model invented are dropped.** Anything outside the declared schema is discarded before the sub-agent's method is called, so a hallucinated key produces a working call rather than an `ArgumentError`. If a real parameter is being dropped, it is missing from the contract.

## Related Documentation

- [Tools](/actions/tools) — the function-calling layer delegation is built on
- [Structured Output](/actions/structured_output) — how declared `returns` schemas reach the provider
- [Instrumentation](/framework/instrumentation) — subscribing to delegation events
- [Mock Provider](/providers/mock) — running delegations offline in tests
- [Generation](/agents/generation) — executing delegation-enabled generations
- [Configuration](/framework/configuration) — provider configuration backends resolve against
