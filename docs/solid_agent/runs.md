---
title: Runs, Cohorts & Cost
description: AgentRun records each execution with lifecycle status, an append-only progress stream a UI can poll, instruction-fingerprint cohorts for comparing prompt changes, and estimated spend.
---
# {{ $frontmatter.title }}

A [context](/solid_agent/context) records the conversation. An `AgentRun`
records the *execution*: it started, this is what it was given, here is
where it got to, it finished (or didn't), it cost this much.

That distinction matters as soon as the work moves off the request thread.
A job running for forty seconds has no conversation to show yet, but it has
a status and a progress stream — and the browser needs something to poll.

Nothing creates runs for you. The executor does: a job, a service object,
the [dashboard's](/framework/dashboard) execution service.

## Recording a run

```ruby
run = AgentRun.create!(
  runnable: document,              # polymorphic, optional
  agent_name: "ReportAgent",
  action_name: "analyze",
  input_prompt: question,
  input_params: { document_id: document.id },
  trace_id: SecureRandom.uuid      # shared with contexts, generations, telemetry
)

run.record_instructions(ReportAgent::INSTRUCTIONS)  # cohort fingerprint
run.start!

run.append_event(kind: "llm", label: "analyze", eid: "gen-1", status: "started")

response = ReportAgent.with(document: document, question: question, trace_id: run.trace_id)
  .analyze.generate_now

run.append_event(kind: "llm", label: "analyze", eid: "gen-1", status: "done", duration_ms: 1840)

run.complete!(
  output: response.message.content,
  input_tokens: response.usage&.input_tokens,
  output_tokens: response.usage&.output_tokens
)
```

### Lifecycle

`pending → running → complete | failed | cancelled`

| Method | Does |
|--------|------|
| `start!` | `running`, stamps `started_at` |
| `complete!(output:, metadata:, input_tokens:, output_tokens:)` | `complete`, stamps `completed_at`, computes `duration_ms` |
| `fail!(error)` | `failed`, records the message, stamps and computes duration |
| `cancel!` | `cancelled` — returns `false` if the run already finished |

Predicates come with it: `pending?`, `running?`, `complete?`, `failed?`,
`cancelled?`, plus `in_progress?` and `finished?`.

## The progress stream

`append_event` appends to a JSON column with `update_column` — no
validations, no callbacks, safe to call from the run's own thread while it
works. Read-modify-write on a JSON column would drop entries when two
writers race, so the re-read and the write are serialized by a row lock:
an append made while another is in flight lands after it rather than on
top of it.

```ruby
run.append_event(kind: "tool", label: "fetch_url", eid: "e1", status: "started")
run.append_event(kind: "tool", label: "fetch_url", eid: "e1", status: "done", duration_ms: 120)
```

| Field | Meaning |
|-------|---------|
| `kind` | What ran — `llm`, `tool`, `agent`, whatever your UI groups by |
| `label` | Display name |
| `eid` | Pairs a `started` event with its `done` / `error` — anything still unpaired is in flight |
| `status` | `started`, `done`, `error` |
| `detail` | Free text, truncated to 1200 bytes |
| `duration_ms` | For finished events |

Which makes the polling endpoint boring, which is the point:

```ruby
def show
  run = AgentRun.find(params[:id])

  render json: {
    status: run.status,
    in_progress: run.in_progress?,
    events: run.events,
    output: run.output,
    error: run.error_message,
    duration_ms: run.calculated_duration_ms(fallback_end: Time.current)
  }
end
```

## Cohorts: did the new prompt help?

`record_instructions` stores an 8-character digest of the instructions the
run executed under. Runs sharing a digest are one cohort — the grouping key
for "we changed the prompt on Tuesday, did anything get better?"

Digests read badly in a UI, so every digest also has a deterministic
codename derived from it alone — stable across runs, deploys and machines:

```ruby
run.instructions_digest    # => "a1b2c3d4"
run.instructions_codename  # => "calm-heron"
```

```ruby
AgentRun.for_agent("ReportAgent").where(status: "complete")
  .group(:instructions_digest)
  .average(:duration_ms)
  .transform_keys { |digest| SolidAgent::RunFingerprint.codename(digest) }
# => { "calm-heron" => 2400.0, "misty-atoll" => 1810.0 }
```

`calm-heron` vs `misty-atoll` is a conversation a team can have. Both
helpers are available without a run record:

```ruby
SolidAgent::RunFingerprint.digest(instructions)
SolidAgent::RunFingerprint.codename(digest)
```

## Querying runs

```ruby
AgentRun.recent.limit(20)
AgentRun.for_agent("ReportAgent")
AgentRun.for_action("analyze")
AgentRun.for_status("failed")
AgentRun.with_trace(trace_id)

run.total_tokens
run.calculated_duration_ms(fallback_end: Time.current)  # works mid-run too
```

Because `trace_id` is shared, one id joins the run, the conversation, the
generations and your [telemetry](/framework/telemetry) trace:

```ruby
AgentRun.with_trace(id)
AgentContext.with_trace(id)
AgentGeneration.with_trace(id)
```

## Cost

Generations store token counts. Pricing sits on top, which is why every
figure here is an estimate:

```ruby
SolidAgent::ModelPricing.estimate(
  model: "claude-sonnet-5", input_tokens: 12_000, output_tokens: 800
)
# => 0.048

SolidAgent::ModelPricing.rate_for("gpt-4o-mini")  # => [0.15, 0.6] per 1M tokens
```

Rates come from RubyLLM's model registry when that gem is loaded and knows
the model, from a static pattern table otherwise, and from a conservative
blended rate for anything unrecognized — so totals stay meaningful for
self-hosted and aliased models instead of silently reading zero. Models
matching `/mock/i` price at zero, so test runs don't inflate anything.

The generated `AgentGeneration#estimated_cost` uses it automatically, and
takes explicit rates when you've negotiated your own:

```ruby
generation.estimated_cost
generation.estimated_cost(input_price_per_million: 0.10, output_price_per_million: 0.40)
```

Spend for a day, by model — pricing is per-model, so total it in Ruby:

```ruby
AgentGeneration.where(created_at: 1.day.ago..)
  .group_by(&:model)
  .transform_values { |gens| gens.sum { |g| g.estimated_cost.to_f }.round(4) }
```

## See also

- [Dev Console (Dashboard Engine)](/framework/dashboard) — runs, traces and metrics with a UI on top
- [Telemetry](/framework/telemetry) — the trace side of the same id
- [Generation](/agents/generation) — sync and async execution
- [Examples](/solid_agent/examples#run-tracking) — the worked example
