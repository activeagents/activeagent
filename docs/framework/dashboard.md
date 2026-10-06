# Dev Console (Dashboard Engine)

The dashboard is its own gem. `activeagent` is the framework — agents,
providers, generation, telemetry reporting — and `actionagent` is a mountable
Rails engine that adds the dashboard on top of it: every agent generation
recorded as a trace with a span waterfall, a metrics overview, and the
agent builder, interactions and evaluations alongside them — running
inside your app against your own database while you build. The hosted
[activeagents.ai](https://activeagents.ai) platform mounts the same engine,
so what you see locally in development is what the platform shows (plus the
accounts, plans, billing and managed sandbox infrastructure a hosted
product has to have) once you point telemetry at it. Every platform
workspace starts with a free low-volume trial.

![Dashboard: traces list with expandable span timelines]

## Quick start

The dashboard's models are Active Record models and its runs persist
conversations, so `actionagent` adds `activerecord` and
[solid_agent](/solid_agent) on top of what the framework already pulls in —
neither of which `activeagent` itself requires. Add both gems:

```ruby
# Gemfile
gem "activeagent"
gem "actionagent"
```

```bash
bundle install
rails generate action_agent:install
rails db:migrate
```

The generator:

- copies three migrations — `active_agent_telemetry_traces` (the trace
  store), `active_agent_dashboard_tables` (agents, runs, versions,
  conversations, evaluations, sandboxes, recordings, keys) and
  `active_agent_evaluation_scenarios` (scenario suites and their per-model
  results; re-run the generator on an existing install to get it); pass
  `--traces_only` for a trace sink alone,
- mounts the engine at `/activeagents`,
- writes `config/initializers/action_agent.rb`.

API keys and provider credentials are encrypted at rest, so run
`rails db:encryption:init` before creating any (or set
`ActionAgent.encrypt_credentials = false` to store them in plain
text — a deliberate downgrade, not a default).

Deploying this beyond your laptop — for a team, or as the trace sink for
a fleet of apps? See
[Self-Hosted Observability](/framework/self-hosted-observability).

Then enable telemetry with local storage in `config/active_agent.yml`:

```yaml
telemetry:
  enabled: true
  local_storage: true
```

That's it. Run any agent and open `/activeagents` — each generation
appears as a trace with prompt/LLM/tool spans, timing, token usage
(input / output / thinking), provider and model. The dashboard's React
bundle ships prebuilt in the `actionagent` gem, so mounting it doesn't ask
your app to run a JavaScript build.

`local_storage: true` writes traces through the engine's trace model, so it
only works in the app that mounts the engine. Without `actionagent`
installed, telemetry logs that it has nowhere to write — apps that only run
agents point telemetry at an `endpoint:` instead (see below).

## What you get

| Page | Path | Contents |
|------|------|----------|
| Ask ActiveAgents | `/activeagents/assistant` | Ask about recorded evaluations and prepare an agent draft for review (development and test only — see below) |
| Agents | `/activeagents` | Your agents with per-agent request, token and error stats; build, edit, version them, and test them as a user in the Run Agent workbench (see below) |
| Traces | `/activeagents/traces` | Every generation: agent + action, status, duration, tokens; expandable span timeline; All/Errors filter; 30s auto-refresh |
| Metrics | `/activeagents/metrics` | The service overview: golden signals, six time series over 1h/24h/7d, and the top agents, models, actions, tools and error types (see below) |
| Interactions | `/activeagents/interactions` | The conversations behind the traces: messages, tool calls, generations |
| Evaluations | `/activeagents/evaluations` | Scored agent outputs, and scenario suites replayed across models (see below) |
| Console | `/activeagents/console/traces` | The same traces and metrics server-rendered, without JavaScript; span waterfall per trace at `/activeagents/console/traces/:id` |
| Ingest API | `POST /activeagents/api/traces` | JSON trace ingestion from other apps and SDKs (`local_storage` writes through the model instead, no HTTP) |

## Testing an agent as a user

Every agent page has a **Run Agent** button. It opens a workbench that works
the agent the way a user would — a conversation, not a one-shot prompt box —
so you can watch what the model is given, change it, and run again.

![Run Agent: a pinned conversation with the live activity feed and the composer](/dashboard/runner-overview.png)

**Add user messages.** Type a message and press Run (or ⌘/Ctrl+Enter). The
run executes under the agent's instructions and the selected action, and the
reply streams into the conversation with the same LLM/tool activity feed the
Interactions view shows. The conversation is *pinned*: the next message is
sent with every user and assistant turn before it, so "and which one grew
fastest?" means what it would mean to a person. Each run is still its own
`AgentRun` with its own trace, which is how Traces and Interactions keep
showing exactly what the model saw.

<video src="/dashboard/runner-messages.webm" controls muted playsinline width="100%"></video>

The workbench follows the dashboard theme:

![Run Agent in dark mode](/dashboard/runner-overview-dark.png)

**Modify the context.** The conversation on the page is the persisted
solid_agent context, and it is editable: hover a turn to **edit** or
**delete** it, use **Add message** to seed a user or assistant turn without
running anything, and **New conversation** to start from an empty context.
The system row shows the composed instructions the run executes under (edit
those on the Instructions tab). Editing a previous question and asking a
follow-up is the quickest way to see how an agent handles a changed history.

![Context editing: the second question rewritten, and the follow-up answering the rewritten history](/dashboard/runner-context-editing.png)

<video src="/dashboard/runner-context.webm" controls muted playsinline width="100%"></video>

**Attach files.** Files attached to a message upload with the run through
Active Storage (`AgentRun has_many_attached :attachments`), and reach the
model according to their kind: images as vision input, PDFs as documents,
and text-like files — CSV, Markdown, JSON, plain text — inlined into the
message, with the filename and size in a header the model can cite. The
persisted user message keeps an attachment manifest, so the conversation
shows the thumbnails afterwards. A host app without Active Storage keeps
everything else and answers attachment uploads with a clear 422.

![Attachments: a CSV attached to a message, answered with stats and a chart built from its rows](/dashboard/runner-attachments.png)

![Attachments: an image described by the model, and a PDF summarised into a card](/dashboard/runner-attachments-image.png)

<video src="/dashboard/runner-attachments.webm" controls muted playsinline width="100%"></video>

**Generative UI.** An assistant reply can carry UI instead of, or alongside,
prose: cards, stats, tables, charts, lists, progress bars, forms, choice
buttons, images, callouts and code. Three ways in, all rendered by the same
component:

- a fenced ```` ```ui ```` block in a markdown reply whose body is JSON —
  an array of blocks, or `{ "blocks": [...] }`;
- a JSON reply whose top level is `{ "ui": [...] }` (a `response_format`
  agent, say) — any other JSON object renders as a key/value block;
- the **Generative UI** tool (`render_ui`) — enable it on the agent's Tools
  tab and the model can call it with `{ "blocks": [...] }`.

Forms and choices are live: submitting a form or clicking a choice posts the
answer back into the conversation as the next user message, so a model can
ask for input and continue. To stop inside a tool call instead, and continue
the same run with the answer, give the agent the `ask` tools (see
[Input requests](#input-requests)).

![Generative UI: stats, a chart and a table rendered from a render_ui tool call](/dashboard/runner-generative-ui.png)

![Generative UI: a form the model asked the user to fill in](/dashboard/runner-generative-ui-form.png)

![Generative UI: the confirmation card and choice buttons after the form was submitted](/dashboard/runner-generative-ui-confirmation.png)

While a run executes, the LLM and tool calls stream into the conversation
as they happen — here a `calculate` call answered mid-run:

![The live activity feed during a run, with a tool call already answered](/dashboard/runner-tool-call.png)

<video src="/dashboard/runner-generative-ui.webm" controls muted playsinline width="100%"></video>

```json
[
  { "type": "stats", "items": [
    { "label": "Revenue", "value": "$3.36M", "delta": "+11%", "tone": "positive" },
    { "label": "Deals", "value": "113" }
  ]},
  { "type": "chart", "chart": "bar", "title": "Revenue by region",
    "x": "region", "series": ["revenue"],
    "data": [ { "region": "EMEA", "revenue": 1240000 }, { "region": "APAC", "revenue": 710000 } ] },
  { "type": "form", "title": "Book a follow-up", "submit": "Book call",
    "fields": [
      { "name": "date", "label": "Date", "type": "text", "required": true },
      { "name": "time", "label": "Time", "type": "select", "options": ["09:00", "11:00", "15:00"] }
    ]}
]
```

Block fields: `card {title, body, image_url, footer}`, `stat {label, value,
delta, tone}`, `stats {items}`, `table {columns, rows}`, `chart {chart:
bar|line|area|pie, title, x, series, data}`, `list {title, items, ordered}`,
`progress {label, value}`, `form {title, submit, fields[{name, label, type:
text|textarea|number|select|checkbox, options, placeholder, required}]}`,
`choices {prompt, options}`, `image {url, alt, caption}`, `callout {tone,
title, body}`, `code {language, code}`.

Blocks are rendered as React elements only, never as HTML. An `image` (or a
card's `image_url`) is displayed straight away when it is a `data:image/…`
URL or one of your own app's — an Active Storage blob, say. A URL on any
other host is shown as a button naming that host instead: fetching an image
is a request to whoever serves it, and the model chose the address, so the
person reading the reply decides whether to make it.

Time-series charts on the console's metrics page use the optional
[groupdate](https://github.com/ankane/groupdate) gem when present and
degrade gracefully without it; the React metrics page reads buckets the
API already aggregated and needs nothing extra.

## Input requests

A dashboard agent can stop partway through a run to ask a person something,
then continue the same run with the answer. This is the framework's
[input requests](/framework/input_requests) feature, stored and answered by the
engine. It differs from a Generative UI form or choice in four ways:

- **The run stops inside a tool call.** The answer becomes that call's result
  in the same run and trace, and the model continues from the turn that made
  the call. A Generative UI answer starts a new run, and the model reads it as
  the next user message.
- **An approval can come before a side effect.** A Generative UI form can only
  ask after the model has acted or stopped.
- **A request is a stored record** with an owner, a status and an expiry. It
  can be answered through the API or the MCP facade, and the paused run
  survives a worker restart.
- **A secret answer never reaches the model.** It goes to the tool without
  passing through the conversation or telemetry.

**Asking.** Enable the `ask` tools on the agent's Tools tab:

| Tool | Request it raises | What the model reads |
|---|---|---|
| `ask_user(question:, options:)` | `text`, or `choice` when `options` are given | `{ "answer": ... }` |
| `request_approval(action:)` | `confirm`, describing the action | `{ "approved": true }`, or an error when declined |

`request_secret` raises a `secret` request. It is offered only to agents the
engine defines itself, never through an agent's tools list, and the value goes
to the engine's handler for that agent. The model reads `{ "provided": true,
"name": ... }`.

**Approvals.** An agent's `approval_required_tools` names the tools whose calls
wait for a person: toolbox tools, schema tools and its MCP servers' tools. Set
it with the **Approval** switch beside each enabled tool on the agent's Tools
tab, or through the agents API. A capability's switch lists every function it
exposes (`memory` holds both `save_memory` and `recall_memory`), and the tool
roster endpoint returns those names as each row's `approval_names`. A
call to a listed tool raises a `confirm` request that carries the call's
arguments, before the tool runs. Approved, the tool runs once. Declined, it
never runs, and the model reads an error. The list is part of the agent's
versioned configuration, and changing it makes the agent's evaluations stale,
because a replay that calls a listed tool pauses. An agent run from its host class uses the framework's
own approval declarations instead.

**While a run waits.** Its status is `awaiting_input`, with one request per
paused tool call. The requests of one pause share the checkpoint the run
resumes from, encrypted at rest like each `answer` when `encrypt_credentials`
is on. Once every request of the pause is answered or declined,
`ActionAgent::AgentResumeJob` continues the run:

- It runs under the same trace id, and the resumed segment's spans join the
  run's trace.
- Its tokens and duration add to the run's.
- The conversation keeps the run's user message once.

The job's only argument is a request id. It reads and decrypts the answers
itself, and clears a secret answer once the resume has run.
Cancelling the run cancels its pending requests. `config.input_request_ttl`
(one day by default, `nil` for no limit) sets how long a request waits. Past
it, the request expires, the rest of its pause is cancelled, and the run
fails. That happens when an answer arrives, when the request list or the
run's page is read, or when `ActionAgent::InputRequestExpiryJob` runs. The job
is not scheduled by default:

```yaml
# config/recurring.yml
input_request_expiry:
  class: ActionAgent::InputRequestExpiryJob
  schedule: every 15 minutes
```

| Endpoint | What it does |
|---|---|
| `GET /api/input_requests` | The caller's pending requests, newest first. `status` (a status, or `all`), `agent_id` and `run_id` filter them. Each entry has the id, kind, prompt, options, tool name, a `confirm` request's arguments, the agent, the run id, the run's actor, `created_at` and `expires_at`, and never the answer or the checkpoint |
| `POST /api/input_requests/:id/answer` | Answers with `answer`. A `confirm` request is approved by `true` or by no answer, and declined by `false` |
| `POST /api/input_requests/:id/decline` | Declines: the paused tool does not run |

`GET /api/runs/:id` lists the run's pending requests in the same shape. An
answer or a decline returns:

- **404** for a request of a run the caller cannot see. A request is found
  through its run, so the list and `GET /api/runs/:id` show the same requests.
- **403** when:
  - `permission_checker` denies `:answer_input_request`. The checker receives
    the request: its `subject` is the run, and its `requested_by_id` is the
    run's actor when that is a user.
  - no checker is set, the install is multi-tenant, and the signed-in user is
    not the actor the request records, because the run acts as that actor.
  - no user is signed in, in multi-tenant mode.
  - `execution_enabled` is off, because settling a pause resumes the run. A
    resume job that finds execution turned off fails the run.
- **409** when the request is no longer pending or has expired. The body's
  `status` says which, and an expired request fails its run.
- **422** for a blank answer, a `choice` answer that is not one of the
  options, a `secret` answer shorter than 8 characters, or a `confirm` answer
  other than `true` or `false`. A secret is scrubbed from the run's records
  wherever it appears inside a value, so a shorter one would also mask
  unrelated text.

**Answering in the dashboard.** The Interactions item in the sidebar shows
how many requests are waiting, and Interactions opens with a **Needs input**
lane that lists them, newest first. The runner shows a paused run's requests
inline. Each request is a card that says which agent is asking, which run it
paused, who the run acts for, which tool asked, and when the request expires.
The control depends on the kind:

- `text`: a text field
- `choice`: the option buttons
- `confirm`: Approve and Decline, beside the call's arguments
- `secret`: a password field with `autocomplete="off"` and `data-aa-secret`,
  emptied as soon as it is sent

Any request can also be declined. A card posts to the answer and decline
endpoints and never starts a run, and it reports a 409 as already answered,
declined, expired or cancelled. In the runner, a paused run stays in flight:
after each answer the runner polls the same run until its reply lands in the
same conversation. A lane card links to the runner opened on its run
(`/agents/:id/run?run=:run_id`). Opening another conversation in the runner
while a run waits lets go of that run, which keeps waiting in the lane. The
dashboard polls for requests (the badge every 30 seconds and whenever the
view changes), because the engine pushes no updates for them.

**Callers that wait for a result.**

- `POST /api/agents/:id/test` returns the paused run.
- An MCP `run_<slug>` call returns the run id, the `awaiting_input` status and
  the request ids.
- `call_agent` returns `{ "error": "input_required", "questions": [...] }` to
  the calling model and cancels the called agent's run.
- An evaluation replay records "paused for input" as the scenario's error and
  cancels the run.

Pausing works on Anthropic and on the OpenAI Chat Completions-based providers.
An `openai` agent uses the Responses API unless its credentials set
`api_version: :chat`, and there a tool that asks fails the run with
`ActiveAgent::InputRequest::UnsupportedProviderError`.

## Ask ActiveAgents

A tool for developing and CI-ing agents, not a production surface. Answering a
question means sending recorded prompts, outputs and evaluation report excerpts
to a model provider, so the page and its API are available in development and
test only. Where it is off there is no nav item, no route and no endpoint —
both `/activeagents/api/dashboard_assistant` actions answer `403`. Turn it on
somewhere else deliberately, or off everywhere:

```ruby
# config/initializers/action_agent.rb
ActionAgent.configure do |config|
  config.assistant_enabled = true   # or false to remove it in development too
end
```

Choose a provider and model, then allow that provider to process your message,
recent conversation history and authorized report excerpts. Configure a provider
credential in Settings first. The assistant uses the host's authentication,
agent scope, execution policy and quota hooks.

Ask which demo questions passed, why an evaluation failed, or describe an agent
to build. Report cards link to recorded evidence and disclose weak checks and
missing provenance. Historical passes cannot establish that current main works.
Compact report references remain available when earlier excerpts are replaced.
Raw recorded exceptions are withheld from assistant evidence because they may
contain credentials; open the authorized report to inspect those details.
Agent drafts open in the builder for review; they are not saved or run by chat.

Conversation state resets on reload. Assistant generations disable framework
traces and provider notifications, and message/history parameters are filtered
before Rails request logging. Provider retention and any host middleware that
records raw HTTP bodies still follow the host's policies.

The assistant's configuration endpoint (`GET /api/dashboard_assistant`)
reports whether GitHub and Claude Code are connected, as booleans with no
tokens. The assistant itself isn't told, and it cannot connect them, start a
checkout sandbox or run a Claude Code session; it points you to Settings →
Integrations, where those live (see
[Local checkout sandboxes](#local-checkout-sandboxes)). COI execution and PR
checks remain [planned work](/plans/dashboard-assistant/PLAN).

## Metrics

`/activeagents/metrics` answers the question an on-call tab is open for:
is this service healthy right now, and if not, since when. It is laid out
the way an APM overview is — golden signals across the top, one grid of
time series under them, top-N lists down the right — because the point is
to see a change and then find what moved, not to read a table.

Pick a window with the `1h` / `24h` / `7d` control. The window fixes the
bucket size the whole page is drawn at — 60 buckets of a minute, 96 of 15
minutes, 84 of two hours — so the charts stay the same shape whatever the
traffic, and the indicator beside the control says which (`live · 15 min
buckets`, refreshed every 60 seconds).

Five golden signals lead: **Requests** (with requests per minute),
**Latency** (p50, with p95 and p99 under it), **Error rate** (with the
error count and how many were rate-limited), **Tokens** (input and output)
and **Cost** (with cost per request). Each carries a 24-point sparkline of
its own series and a delta against the period of the same length just
before the window — more traffic and falling latency read as success, a
rising error rate as error, volume and spend stay neutral, because a
bigger number is not by itself good or bad.

Six panels plot the window:

| Panel | What it shows |
|---|---|
| Requests | Bars per bucket, stacked by agent, with deploy markers |
| Latency | p50 / p95 / p99 lines, with the incident marker |
| Errors | Bars stacked by error class, with the incident marker |
| Tokens | Input and output lines |
| Cost | Estimated spend per bucket |
| Tool calls | Calls per bucket, errored calls stacked on top |

The right rail ranks what is behind them: **Agents** by requests (with
p95, error rate and cost), **Models** by tokens, **Slowest actions** by
p95, **Tools** by calls (with average duration and error rate) and
**Errors by type** — `429 rate limit`, `timeout`, `tool error`,
`provider 5xx`, `other`, always all five so the shape of a spike is
readable at a glance.

Filter to one agent from the select, or by clicking its row in the Agents
rail; clicking it again clears the filter. Everything narrows together —
signals, charts and rails — so the page never shows a filtered chart next
to an unfiltered tile. The rail keeps listing every agent while a filter
is on, with the active one highlighted, so it stays the way to hop
between them. An `env` chip names the environment most of the window's
traces report.

Two kinds of marker sit on the plots. A **deploy** is an agent version
saved inside the window (`v4 · SupportAgent`, or `instructions v4 ·
SupportAgent` when that version changed the instructions — the deploy a
latency or error shift most often traces back to); at most the three most
recent are drawn, because more than that is a picket fence. An
**incident** is the bucket with the most errors when it is a real spike —
at least five errors and at least twice the window's error rate — labelled
by its dominant error class and the agent that errored most in it.

Empty windows say so (`No traffic yet — run an agent, or point your app's
ActiveAgent telemetry at this workspace`) rather than drawing five flat
lines.

### The metrics API

`GET /api/metrics` is what the page reads, and what to point your own
alerting or reporting at:

| Param | Meaning |
|---|---|
| `range` | `1h`, `24h` (default) or `7d` — the window and its bucket size |
| `hours` | A custom window instead, bucketed to about 96 points (`range` then reads `custom`) |
| `agent` | An `agent_class`; every key in the response is scoped to it |
| `sort` | Ranks the per-agent table: `popular`, `longest`, `cost`, `tokens`, `errors` |

The response carries `range`, `bucket_seconds`, `window_minutes`, `agent`
and `environment`, then `totals` (requests, requests per minute, p50 / p95
/ p99 in ms, errors, error rate, tokens in / out / total, cost, cost per
request, tool calls, tool errors, tool error rate), `deltas` against the
previous period (`requests_pct`, `p50_pct`, `error_rate_pt`, `tokens_pct`,
`cost_pct`; null when there is nothing to compare against), `series` (one
entry per bucket, oldest first, zero-filled, each with `ts`, `requests`,
`requests_by_agent`, the three percentiles, `errors`, `errors_by_type`,
`tokens_in`, `tokens_out`, `cost`, `tool_calls`, `tool_errors`), the
`agents`, `models`, `actions` and `tools` rails, `errors_by_type` and
`markers`. The earlier keys — `summary`, `hourly_requests`, `by_agent`,
`window_hours`, `sorts`, `sort` — are still there and still mean what they
did, so anything already reading them keeps working.

Percentiles are nearest-rank over each trace's total duration and are
computed in Ruby from one pass over the window, so PostgreSQL and SQLite
return the same numbers; cost is `ModelPricing`'s estimate per trace from
the model on its first LLM span. `ActionAgent::MetricsReport` is the whole
of it if you would rather call it directly.

## Scenario evaluations

An evaluation scores an agent one of two ways. Without scenarios it samples
the agent's recent recorded generations and scores them against rule,
telemetry and LLM-judge criteria. With scenarios it **replays** a list of
user messages you paste in — one fresh run per scenario, per candidate model
— and reports which tasks the agent completes, what the failures have in
common, and what to change. That is how to answer "can this agent do these
new tasks with the tools it has?" and "how does a frontier model compare with
the latest open-weights model on my workload?" without waiting for traffic.

Paste scenarios into the **Scenarios** field of the New Evaluation form, or
through the API (`scenarios_text`, or a `scenarios` array). One message per
line; `# Heading` lines group related tasks so a group can be run on its own;
options after `|` set expectations:

```text
# Open tickets
Which open tickets mention a refund? | tools: find_tickets
Show me all tickets with no assignee
# Change history
Who changed the shipping policy last week? | contains: policy
```

| Option | Meaning |
|---|---|
| `tools: a, b` | A passing answer calls at least one of these tools |
| `contains: x, y` | The answer must contain each pattern (substring or regex) |
| `not_contains: x` | The answer must not contain the pattern |
| `key: k` | A stable key, so results line up across re-imports |
| `group: g` | Overrides the heading for this line |

**Compare models** holds the candidates, one removable chip each, and
submits them as a comma-separated list, which the API also accepts. Type to
search the suggestions, and finish a name the list lacks with Enter or a
comma. A bare name infers its provider from the family (`claude-*` →
Anthropic, `gpt-*` → OpenAI, `name:tag` → Ollama); prefix it to be explicit
(`ollama/qwen3:8b`, `openrouter/meta-llama/llama-3.3-70b-instruct`). Each
candidate needs credentials the same way an agent run does — the owner's
provider key or the host app's `config/active_agent.yml`.

What the field suggests depends on the scenarios:

- **With scenarios**, each candidate replays them, so the field suggests the
  models of every provider the owner's runs have credentials for, from the
  same catalogs as the agent builder. A model whose name alone would run on
  another provider is offered with its provider in front: `ollama/llama3.2`,
  or `openrouter/anthropic/claude-sonnet-4.5` for OpenRouter's copy of an
  Anthropic model.
- **Without scenarios**, each candidate selects the generations the agent
  recorded under that model name. A provider usually records its dated id
  (`gpt-4o-mini-2024-07-18` for a request for `gpt-4o-mini`), so the field
  suggests the names the agent's generations were recorded under
  (`GET /api/agents/:id/recorded_models`).

Adding or clearing the scenarios renames the catalog models already chosen
to match. **Judge model** suggests the models of the provider the judge runs
on, named under the field: the first of Anthropic, OpenAI and OpenRouter
with credentials, else Ollama when the owner configured a host.
`GET /api/evaluations` reports that provider as `judge_provider`, and the
providers runs can use as `model_providers`. A provider whose credentials
cannot be read, such as a stored key that no longer decrypts, is left out of
`model_providers`. When reading one fails before the judge's provider is
found, `judge_provider` is null with `judge_provider_error: true`, and the
field says the credentials could not be read.

Replays and their judge use the credentials of the evaluated agent's owner.
On an agent's page, which requests the list with `agent_id`, both fields
describe that owner's credentials. The Evaluations page describes the
signed-in owner's, which differ only for an agent someone else owns, as the
host's `agent_scope_resolver` can allow. A host adapter
(`ActionAgent.scenario_evaluation_adapter_resolver`) runs a suite with
whatever credentials it chooses, which these fields do not describe.

The catalogs come from `GET /api/provider_models`. When the host app loads
RubyLLM, it appends the chat models that take and return text from
RubyLLM's model registry for the provider (its bundled catalog, or the
host's own model table) after the live or curated list.

A run is queued (`EvaluationRunJob`) and its results land as each replay
finishes. Each replay runs as the evaluation's owner when agents are owned
per user, so a tool scoped to its caller sees that user's rows; a
multi-tenant install replays unattributed unless a host adapter
(`ActionAgent.scenario_evaluation_adapter_resolver`) runs the suite itself.
The suite card reads top to bottom: is it getting better (Runs), which
model (Models), the evidence per scenario (Scenarios), and then what to fix
(What to fix).

**Runs** lists the suite's history, newest first, numbered `#n` from the
oldest so a number keeps naming the same run once the list is capped. A row
carries when the run finished, a pass bar per model, and its delta against
the previous complete run — `+3 passed vs #7`, green when it moved up, red
when it moved down. A run over a different number of scenarios or models
reads `partial run` instead: those two totals are not comparable and a
delta would lie about it. Selecting an older run re-derives everything below —
models, the matrix, the drill-downs, what to fix — so the whole card
describes the run you are reading, while the collapsed header keeps
reporting the latest.

**Models** gives each candidate its pass bar and `k/n`, mean score, mean
latency, input and output tokens, estimated cost, and the faults it hit as
badges (or `[+] no faults`). The model that did best carries an
info-toned `judge's pick` badge — never a green *winner*, because losing a
comparison by one scenario is not a failing grade — and the **verdict**
line under the panel is the rationale for the pick. The panel says who made
it: the judge model, or `rules` when the run was scored without one and the
ranking is pass rate alone.

**Scenarios** is the matrix: one row per scenario, one column per model,
filtered by group chips or `[ ] failed only`. Each row shows the tools the
scenario expects as chips, and each cell the `[+]`/`[!]` glyph, the score,
the fault, and the tools that model actually called — coloured against the
expectation, so a call that satisfies it reads green, one that errored red
with `✗`, and anything else stays muted (`no tools called` when there were
none). Group rows carry `k/n passed` per model. Opening a row drills into
it: each model's answer, its tool calls, its timing, tokens and cost, and
the diagnosis behind its fault, with `re-run scenario ->` to replay that
one on its own and a `[x] enabled` toggle to keep it out of later runs.

**What to fix** turns the faults into work. One card per fault, plus one
per instruction change the judge proposed, each naming the scope it speaks
for (`3 scenarios · both models`), the fix it calls for, and the tools
involved — deduplicated to one chip per tool, whatever the number of
scenarios that hit it: the missing tools a scenario expected, the tools
that errored, or the tools the judge suggested adding. When every missing
tool resolves to the same MCP server the card names it (`served by
Playwright`) and says whether this agent has it enabled or merely has it
available, which is usually the whole diagnosis. The action follows from
that: **Enable *server* for *Agent*** deep-links to MCP Services, failing
or suggested tools to Tools, an instruction change to the agent's
instructions — in-app, with the run still open behind it.

The footer states the run's terms — the judge, the criteria it scored on,
what it cost — and links to `run report ->`: the same self-contained page
`Report#to_html` writes for a CLI run, framed in the dashboard's own theme
so it does not flash white inside a dark console. *Open standalone* opens
the unframed page, which is the copy to archive next to a CI run.
`Delete suite`, on the right, takes the suite and its runs with it.

**Costs** are never blank where tokens exist. Each result is priced down a
chain (`ActionAgent::EvaluationRunCost`): the cost the publishing
application reported, else the estimate the engine stored when it ran the
replay, else the result's tokens × the model's rate, else the tokens of the
trace the result links to, else its text at four characters a token as a
lower bound; a result that recorded zero tokens (an errored replay) costs
`$0.00`. A reported figure reads `$0.0243`, an estimated one `~$0.0243`,
and any sum with an estimated part carries the `~`; a surface that shows
one carries the legend once, *~ estimated from tokens × model rates*, and
the figure's tooltip shows the working. Rates come from RubyLLM's model
registry under the provider the model ran on (`ActionAgent::ModelPricing`:
`gpt-5.5` through OpenRouter is OpenRouter's entry), else from the static
tables; a figure at a pattern or default rate says `(fallback rate)`. The
judge's spend is kept apart — from the engine's meter, from what the
application reported, or from the judge traces priced on their input and
output tokens (never their thinking tokens, which the output count already
holds) — and shown per model (a **Judge** column), per scenario (`judge
~$0.0015` under the matrix's trailing **Cost** column, which sums each
scenario across the models, with group subtotals) and in total. A
finished run's figures are cached under the run, its update time and the
pricing tables in force.

**Standing.** The Evaluations page's pass rate describes the agent as it
is now: the tiles pool only the headline run — the newest complete run —
of each evaluation whose standing is `current` (that run scored the
agent's current version) or `unrecorded` (nothing says which version it
scored, and the agent has no release to compare with), and say how many
evaluations were left out as `stale` (last run against an earlier version)
or `archived`. Only edits the model can see count as a new version: the
instructions, action prompts, tools, MCP servers, model config and
response format; an appearance edit does not. A run the engine executes
is pinned to the agent's version as it runs; a published run is pinned to
the release its report names (`report.release`), and stays unrecorded
without one. A newer run still pending or failed shows beside the
headline run, never in its place. Archive an evaluation nobody maintains
from its card: it keeps its history but leaves the index and the pooled
figures until *Show archived*; a new run or a published report brings it
back. The agent cards' **Eval** tile is the same pooled pass rate.

A scenario passes when the run completed, met its expectations, and scored
at least 0.7 across the evaluation's criteria. Anything else carries exactly
one fault, assigned from the evidence in this order:

| Fault | Meaning | Typical fix |
|---|---|---|
| `run_error` | The replay raised, or the model returned nothing | Credentials, model name, throttling |
| `tool_error` | A tool the agent called returned an error | Fix the tool, or its parameter descriptions |
| `missing_capability` | The agent said no tool covers the task | Add the tool the recommendation names |
| `expected_tool_not_called` | The scenario expects a tool the agent did not call | Enable the tool, or sharpen its description / the instructions |
| `ungrounded_answer` | The agent had tools, called none, and still stated specifics — a count, an id, a date — nothing supplied | Instruct it to answer only from tool results; add the tool that returns this data |
| `forbidden_content` / `missing_content` | A content expectation failed | Instructions, or the tool's output |
| `low_quality` | Criteria scored the answer below 0.7 | Read the answer against the weakest criterion |

`missing_capability`, `expected_tool_not_called` and `ungrounded_answer` are
the faults that turn a pasted list of new tasks into a backlog: they say which
tasks the current toolset cannot reach and what to build. The last two also
tell an honest gap from an invented answer: `expected_tool_not_called` carries
`ungrounded: true` in its evidence when the answer stated specifics no tool
supplied, and `ungrounded_answer` is the same finding for a scenario that
names no expected tool.

The parsing, scoring, diagnosis and report are the framework's
[`ActiveAgent::Evals`](/framework/evaluations); the engine adds the
persistence, the job, the API and the UI. An app can run the same
evaluations against its own agent from Ruby with that module alone.

The API: `POST /api/evaluations` with `scenarios_text`;
`POST /api/evaluations/:id/run` with `group`, `keys[]`, `scenario_ids[]`
and `models[]`; `GET /api/evaluations/:id/runs/:run_id` for the results,
which carry the same `fix_items` the What-to-fix cards are built from,
server resolution included, each result's `cost` (effective),
`reported_cost`, `cost_source`, `cost_rate` and `judge_usage`, and the
run's `costs` (`scenarios` keyed by scenario, each with `cost`,
`judge_cost`, `total`, `estimated` and `models`; and `run` with
`agent_cost`, `judge_cost`, `total`, `cost_basis`);
`GET`/`PUT /api/evaluations/:id/scenarios` to read or replace the suite;
`PATCH /api/evaluations/:id` with `evaluation: { archived: true | false }`
to archive or bring back; and
`GET /api/evaluations/:id/runs/:run_id/report` for the HTML report, with
`?theme=dark` or `?theme=light` to pin its palette. `GET /api/evaluations`
leaves archived evaluations out unless `?archived=1`, returns
`archived_count`, and gives each evaluation its `standing`,
`headline_run_id`, `archived_at` and `per_model` passes, plus the
`headline_run` in full when a newer run is pending or failed; every run
carries its `agent_version` (`id`, `number`, `release_digest`, `revision`,
`release`) and `version_state` (`current`, `earlier` or `unrecorded`).

## The MCP facade

The dashboard is itself an MCP server: `POST <mount>/mcp` speaks Streamable
HTTP JSON-RPC, authenticated with a dashboard API key (Settings → API Keys)
as a Bearer token. Connect a client with:

```json
{ "type": "http", "url": "https://example.com/activeagents/mcp",
  "headers": { "Authorization": "Bearer aa_..." } }
```

`tools/list` offers three kinds of tool: the two below, and the dashboard's
[evaluation and telemetry tools](#evaluations-and-telemetry-from-your-coding-harness).

| Tool | What a call does |
|---|---|
| `run_<slug>` (one per agent the key can reach) | Runs that agent with `{ message }` and returns its answer; a named action marked *expose as tool* is `run_<slug>__<action>` |
| `find_<records>`, `count_<records>`, `get_<record>` (one set per discovered [schema tools](/actions/tools#bounded-reads-over-a-model-schema-tools) class) | Reads the host's records directly, with the tool's own parameter schema, so a client that only needs the rows does not have to ask an agent for them |

Every call runs as **the key's caller** — the user who created the key in
Settings, else the key's owner, or whatever
`ActionAgent.agent_actor_resolver` returns for the request — so a schema
tool's `scope` sees the same actor it would inside an agent run, and an
agent's own authorization callbacks decide against the same person. A
boundary violation (an undeclared filter, an id the caller cannot see) comes
back as a tool result with `isError`, the shape an agent's model would get;
a refusal raised by the host's scope or by an agent answers as a JSON-RPC
error (`-32003`), never as an empty, confident result. Direct reads run no
generation, so neither `execution_enabled` nor the execution quota applies to
them. Set `ActionAgent.mcp_schema_tools = false` to keep schema tools
reachable only through agents. `agent://<slug>` resources return each
agent's live scorecard.

### Evaluations and telemetry from your coding harness

The facade also serves the dashboard's own evaluation and telemetry tools, so
the coding harness you already use (Claude Code, Codex, Cursor, …) can edit an
agent in your checkout, run its evaluations, read what failed, and try again.
The harness brings its own model and login; the dashboard only answers the
calls.

| Tool | What a call does |
|---|---|
| `evaluations_list` | Lists the evaluations of the key's agents, newest first, each with its latest run's status and score; `agent` (slug or id) filters to one agent |
| `evaluations_get` | One evaluation: its criteria, its scenarios and its 10 most recent runs |
| `evaluations_create` | Creates an evaluation of one of the key's agents (`agent`, slug or id) named `name`, with optional `judge_kind`, `judge_model`, `criteria` and `compare_models`. Given scenarios it is a scenario suite; without them it scores the agent's recorded generations. Runs nothing |
| `scenarios_merge` | Adds scenarios to an evaluation (`evaluation_id`) and updates the ones whose keys it already holds. Returns the `added`, `updated` and `unchanged` keys and the suite's size |
| `evaluations_run` | Starts a run. Takes the same selection as `POST /api/evaluations/:id/run`: `scenario_ids`, `keys`, `group`, `models` and `sandbox_id`. A scenario suite runs in the background and comes back `pending` with its run id; a sampling evaluation finishes before the call returns |
| `evaluation_runs_get` | One run (the latest by default): status, scores, usage, fix items and per-scenario, per-model results, each naming its telemetry trace when one was recorded. `failed_only` and `limit` narrow the results |
| `evaluation_runs_compare` | Two runs of one evaluation, result by result: fixed, regressed, still failing, added, removed. Defaults to the latest run against the one before it |
| `traces_search` | Summary rows of traces, newest first, filtered by `agent` (class name or dashboard slug), `status` (`error` or `ok`), `service`, `since_minutes`, `min_tokens` and `min_duration_ms`; at most 100 |
| `traces_get` | One trace by id, OpenTelemetry trace id or its first 8 characters: spans, tool calls with their arguments and results, tokens, estimated cost and failed spans |
| `input_requests_list` | The pending [input requests](#input-requests) of the key's runs, newest first, in the API's shape; `run_id` filters to one run |
| `input_requests_answer` | Answers a `text` or `choice` request as the key's caller, under the same permission check as the API. A `confirm` or `secret` request is refused with an error that points to the dashboard |

A typical loop: `evaluations_run`, poll `evaluation_runs_get` until the run is
`complete`, read the fix items and a failing result's trace with
`traces_get`, edit the agent, run again, and check the change with
`evaluation_runs_compare`. Passing `sandbox_id` runs the evaluation against a
checkout sandbox's app tools without editing the agent (see
[checkout sandboxes](#github-connections-and-checkout-sandboxes)).

The tools read what the JSON API reads for the key's owner: evaluations of
the agents the owner can reach, and traces of the owner's tenant (every trace,
in an install that is not multi-tenant). Another owner's evaluation or trace
answers exactly as a nonexistent one does. `evaluations_run` is checked the
way the JSON API checks a run: a scenario suite needs `execution_enabled` and
execution quota, which answer as JSON-RPC errors as they do for `run_<slug>`,
while an observed agent, an unknown id or a sandbox the run cannot use comes
back as a tool result with `isError`. Strings longer than 1,000 characters are
cut and end in `…[truncated: N more characters]`, long lists end in
`[truncated: N more items]`, and the owner's credentials (API key, provider
keys, GitHub token, sandbox runtime tokens, and project secrets with their
URL-encoded and Base64 forms) are masked from every result.

These names are a noun family followed by a verb. Schema tools are always
`find_`, `count_` or `get_` plus a model name, and agent tools are
`run_<slug>`, so no host model (a `Trace` or `Evaluation` model included) and
no agent slug can produce one of them. Set `ActionAgent.mcp_dashboard_tools =
false` to leave the facade serving agents and schema tools only.

### Writing a suite from your harness

A harness that has read or browsed the app can write the questions its users
would ask, create the evaluation with `evaluations_create`, and add more later
with `scenarios_merge`. Both take scenarios in the forms the New Evaluation
form takes: `scenarios_text` (the [pasted line format](#scenario-evaluations),
a JSON array, or a YAML or JSON suite document) or `scenarios`, an array of
`{ prompt, key, group, notes, tools, contains, not_contains }` objects. A suite
document's `production_only` scenarios are left out unless
`include_production_only` is true. Put the expected-answer rubric in `notes`:
it is what the judge grades the answer against.

`scenarios_merge` never removes, disables or reorders a scenario the call does
not name, so a second batch cannot undo the first or the scenarios someone
wrote by hand. For each scenario it is given:

- **A key the evaluation holds** updates that scenario's prompt, group, notes
  and expectations in place. It keeps its results, its position and whether it
  is enabled. A group, notes or expectations the call leaves out are cleared,
  so send the whole scenario, not only the fields that change.
- **A new key** is added after the suite's last scenario, in the order given.
- **No key** gets the next `<group>_<n>` the evaluation does not use, so the
  same keyless batch merged twice is added twice, under distinct keys.
  `key_prefix` puts a namespace in front of generated keys (`batch2` makes
  `batch2_orders_1`), and leaves keys you give alone.

The dashboard's suite editor replaces the whole suite when you save it.

Neither tool runs anything, so neither needs `execution_enabled` or execution
quota; start a run with `evaluations_run`. Both ask the host's
[permission checker](#permissions) about `:replace_scenarios` as the key's
user (the user who created the key), with the evaluation as the subject: the
unsaved one for `evaluations_create`. A refusal answers as a JSON-RPC error
(`-32003`) and writes nothing. With a checker set, a multi-tenant key that
records no creator is refused without asking it. With no checker set, every
key may use both tools, and a multi-tenant install logs a warning at boot.

Each call is checked whole against the limits the report collector uses: 100
evaluations per agent, 2,000 scenarios per evaluation, 2 MiB of scenarios in
one call (their keys, groups, prompts, notes and expectations as JSON), and
200 characters for a scenario's key or group or the judge model. A prompt or
notes larger than 65,535 bytes is refused too. A call that would pass any of
these is refused and writes nothing. Split a larger suite over several
`scenarios_merge` calls.

An observed agent's suite is refused, as `evaluations_run` refuses it, unless
a host adapter replays it. A duplicate name, unknown criteria, a scenario list
that does not parse, or an agent or evaluation outside the key's reach comes
back as a tool result with `isError`.

## GitHub connections and checkout sandboxes

Settings -> **Integrations** gives checkout sandboxes access to GitHub
repositories in one of two ways, and an install can offer both:

- **A GitHub App installation.** An admin installs the dashboard's GitHub
  App on the repositories they choose. Each checkout then gets its own token,
  valid for an hour and limited to that one repository and to reading its
  contents. Nothing stores the token.
- **An OAuth connection.** One person connects their GitHub account, and
  checkouts use that person's token, which carries the `repo` scope and does
  not expire.

In both, the owner then chooses which repositories the workspace may use, and
the selection only keeps repositories GitHub itself lists. When a repository
is selected both ways, its checkouts go through the installation.

### A GitHub App

Settings -> Integrations -> **Create GitHub App** registers the App for you
on a single-tenant dashboard. It posts a manifest to GitHub (under your
account, or under an organization you name), and GitHub returns to the
dashboard, which shows the new App's id, slug, client id, client secret and
private key once, with the lines to add to your configuration. The dashboard
stores none of them. A multi-tenant platform registers its App per
environment instead, and the button is not offered. The manifest goes to
GitHub as a form post from the browser, so a host app whose content security
policy sets `form-action` must allow `https://github.com`.

To register it by hand, create a [GitHub App](https://github.com/settings/apps/new)
with:

- callback URL `<mount>/api/github_installations/callback` (for example
  `https://example.com/activeagents/api/github_installations/callback`)
- **Request user authorization (OAuth) during installation** turned on
- **Redirect on update** turned on, so GitHub also returns after an
  installation that already exists is reconfigured
- repository permissions Contents (read and write), Pull requests (read and
  write) and Metadata (read), and the organization permission Members (read)
- no webhook, and no Workflows, Administration or Secrets permission

Then configure it, and restart the dashboard:

```ruby
ActionAgent.configure do |config|
  config.github_app_id = Rails.application.credentials.dig(:github_app, :id)
  config.github_app_slug = Rails.application.credentials.dig(:github_app, :slug)
  config.github_app_client_id = Rails.application.credentials.dig(:github_app, :client_id)
  config.github_app_client_secret = Rails.application.credentials.dig(:github_app, :client_secret)
  config.github_app_private_key = Rails.application.credentials.dig(:github_app, :private_key)
end
```

Unset, each setting falls back to `GITHUB_APP_ID`, `GITHUB_APP_SLUG`,
`GITHUB_APP_CLIENT_ID`, `GITHUB_APP_CLIENT_SECRET` and
`GITHUB_APP_PRIVATE_KEY`. A private key written on one line with `\n` for
its line breaks is read correctly. The dashboard offers the App once all five
are set (`ActionAgent.github_app_configured?`).

**Install the GitHub App** sends the admin to GitHub to pick the account and
repositories. GitHub then returns to the callback, and the dashboard links the
installation to the owner only when:

- the return carries a state that this browser session issued to the
  signed-in user, and a code from the App's user authorization (a return
  missing either, such as an install started on GitHub itself or a return
  from reconfiguring an installation that already existed, is sent through
  the App's user authorization first), and
- the installation appears in `GET /user/installations` for the authorizing
  GitHub user, and that user is the user account it is installed on, or an
  active admin of its organization.

The authorizing user's token is used for those checks and then dropped. An
installation is linked to one owner at most, and one owner may link several
(a personal account and an organization, say). When a member asks an
organization owner to approve the install, nothing is linked: once an owner
of the organization approves it on GitHub, that owner links it from Settings.
**Unlink** removes the installation from the dashboard; the App stays
installed on GitHub. To link it again, choose **Install the GitHub App**,
pick the account the App is installed on, and save its configuration on
GitHub, which returns to the dashboard when the App has **Redirect on
update** turned on. If GitHub does not return, uninstall the App from that
account on GitHub and install it again from Settings.

When GitHub refuses a token because the installation was removed or
suspended, the dashboard marks the installation, and starting a sandbox from
it asks for a reinstall. **Check again** on a marked installation asks
GitHub once more, and the mark clears as soon as GitHub mints a token for it,
as it does again once a suspended installation is unsuspended. An App
uninstalled from an account comes back as a new installation when it is
installed again; unlink the old one.

### An OAuth connection

Register a [GitHub OAuth app](https://github.com/settings/developers) whose
callback URL is `<mount>/api/github_connection/callback` (for example
`https://example.com/activeagents/api/github_connection/callback`), then
configure it:

```ruby
ActionAgent.configure do |config|
  config.github_client_id = Rails.application.credentials.dig(:github, :client_id)
  config.github_client_secret = Rails.application.credentials.dig(:github, :client_secret)
  # Default "repo read:user"; "public_repo read:user" for public checkouts only.
  config.github_oauth_scopes = "repo read:user"
end
```

Unset, both settings fall back to `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET`.
The token is encrypted at rest like a provider key and is never returned to
the browser.

### Starting a sandbox

**Start sandbox** on a selected repository creates an `app_runtime` sandbox
session. A sandbox backend (see `ActionAgent.sandbox_backends`) does the
following for that session:

1. Reads `sandbox_session.checkout_spec`, which holds `repository`, `ref`,
   `clone_url`, `username` and `token`, and clones it. For a checkout through
   a GitHub App installation, `SandboxProvisionJob` mints the token once,
   just before it calls `create_sandbox`, and only the session object passed
   to `create_sandbox` carries it. A backend reads the spec from that object;
   a copy of the session loaded from the database carries no token.
2. Boots the app. If the app mounts this engine, its MCP facade serves the
   app's agents and schema tools. A backend that takes a
   [boot spec](#bootstrapping-a-checkout-without-the-engine) can also install
   the engine into a Rails app that does not bundle it.
3. Returns `mcp_url:` (and, when the facade needs one, `mcp_token:`, a
   dashboard API key of the booted app) from `create_sandbox`.

The session is then an MCP server keyed `sandbox:<session_id>`, shown on the
sandbox as `runtime_server_key`. Add that key to an agent's MCP servers, and
runs and evaluations of that agent call the checkout's own tools. The lookup
is scoped to the agent's owner, so one tenant cannot name another tenant's
sandbox.

### Opening a draft pull request

A ready checkout sandbox has a **Pull request** card. **Open draft PR** reads
what the checkout changed since it was cloned and shows:

- every changed file, ticked when it may be published, and the reason when it
  may not
- the exact diff of the ticked files
- the new branch's name, and the pull request's title and description

These are never published, and the dialog names the file and the reason:

- anything under `.github/` (the App asks for no Workflows permission)
- symlinks, and submodules or nested repositories
- a file over 1 MB
- a file holding one of the sandbox's secrets (a stored checkout token, the
  Claude Code and Codex credentials it runs with, its runtime's MCP token, the
  OAuth connection's token) or anything shaped like a GitHub token. The value
  is never shown.

One publish carries at most 300 files and 10 MB of the ticked files. A
preview reads at most 300 files and 20 MB (counting each file now and in the
checkout commit), in path order. A file after that is listed as not read and
cannot be ticked: **Only read paths matching** (`app/**, lib/*.rb`) reads
the preview again with fewer files. A publish and a patch read only the files
they were asked for.

Files the repository ignores are not listed at all. A file is published as
the bytes in the checkout: git's clean conversions do not run, so a
repository whose `.gitattributes` sets `eol=crlf` or
`working-tree-encoding`, or a filter such as Git LFS, gets the working-tree
bytes rather than what `git add` would store. **Open draft PR** in the dialog
sends each ticked file with the digest it was previewed at, and a file that
changed since is refused, and the dialog reads the sandbox again. The publish
then runs in `ActionAgent::DraftPullRequestJob`, from the dashboard's own
process:

1. It gets a token for the one repository: an installation token limited to
   Contents and Pull requests write, minted now, or the OAuth connection's
   token.
2. It writes a blob per file, a tree on top of the checkout commit's tree,
   and a commit whose parent is the checkout commit. The commit names no
   author, so GitHub records it as the token's identity, and signs it for an
   App.
3. It creates the branch. A name that already exists on GitHub is refused,
   and no branch is ever overwritten.
4. It opens a draft pull request against the branch the sandbox checked out,
   or the default branch when it checked out a tag or a commit.

No git process ever holds that token. The sandbox backend only lists and
reads files (`changed_files` and `read_file`, below), and several things can
rewrite a checkout's `.git/config`, which decides where git sends a request
and which programs it starts.

**Update draft PR** publishes the ticked files as a new commit on the pull
request's branch, as a fast-forward that is never forced, with the commit
message the dialog asks for. The pull request's title and description stay
as they are. The new commit's tree is the checkout commit's with the ticked
files on top, so the pull request's diff on GitHub is the diff the dialog
showed: a file the branch holds that the update leaves out returns to its
content in the checkout commit, and the dialog names those files. A branch
with commits the dashboard did not publish is not updated, and neither is a
branch with no pull request.

GitHub opens no draft pull request in a private repository of an account on
GitHub Free. The branch is kept, the card links it on GitHub to compare, and
**Open as a regular pull request** opens a regular one. The dashboard never
does that on its own. When opening the pull request fails for another
reason, the branch is kept the same way, and **Open the draft PR again**
tries once more.

A publish still queued or running 15 minutes after it last moved (its worker
died, or none picked it up) is marked failed as stalled, and the sandbox can
publish again.

A publish goes ahead only when:

- `ActionAgent.permission_checker` allows `:publish_pull_request`, asked when
  the user publishes and again when the job runs
- the sandbox is ready or running, since the publish reads its live checkout
- something can write to the repository: the installation the sandbox
  checked out through, while GitHub serves it with write permissions, or
  the OAuth connection. The OAuth connection publishes only for the user who
  connected it (a connection made before the dashboard recorded that user
  must be connected again), and only with the `repo` scope, or `public_repo`
  for a public repository. Its commit and pull request then appear as that
  user.

Where nothing can write, or GitHub refuses the write (403 or 404),
**Download patch** opens the same dialog to choose filtered and scanned files
for a patch for `git am` or `git apply`, built without any GitHub token. The
card reads the pull request's state (open, closed, merged, draft) again at
most once a minute. No agent tool, toolbox tool or MCP tool publishes. Run
`rails g action_agent:install` and `rails db:migrate` for the
`draft_pull_requests` table.

| Endpoint | Does |
|---|---|
| `POST <mount>/api/sandboxes/:id/pull_request/preview` | the changed files, each with its refusal or its diff and digest; `allowlist:` limits what may be published to matching paths (`"app/**"`) |
| `POST <mount>/api/sandboxes/:id/pull_request` | queues a publish of `files: [{ path:, digest: }]` with `title:`, `body:` and `branch:`; `update: true` publishes `files:` onto the last pull request's branch with `message:` as the commit message; `open: true` opens a draft pull request for a branch published without one, and `regular: true` a regular one. A second request while a publish is queued or running answers 409 |
| `GET <mount>/api/sandboxes/:id/pull_request` | the latest pull request, and whether publishing is available and why not |
| `GET <mount>/api/sandboxes/:id/pull_request/patch` | the patch of `paths[]`, or of every publishable file when one read covers them all |

### What a sandbox backend implements

A backend registered in `ActionAgent.sandbox_backends` is a plain class.
`ActionAgent::SandboxOrchestrator` calls whichever of these public methods it
defines, and `orchestrator.supports?(:verb)` answers whether it defines one:

| Method | Required | Returns |
|---|---|---|
| `create_sandbox(session)` | yes | `{ container_name:, url:, mcp_url:, mcp_token: }`. A backend that also takes `boot_config:` is handed a [boot spec](#boot-specs) as a plain Hash, and boots the checkout by it instead of by the checkout's `.activeagents/sandbox.yml` |
| `status(handle)`, `terminate(handle)`, `list_sandboxes`, `cleanup_expired` | yes | a status hash, true, an array of status hashes, a count |
| `run_code_session(session, code_session, &on_event)`, `cancel_code_session(session, code_session)` | no | `{ exit_status:, diff: }`, true |
| `changed_files(session)` | no | `{ base_commit:, files: [{ path:, status:, mode:, base_mode:, size: }] }`: what the checkout changed since it was cloned, without the files the repository ignores, read without running the checkout's git hooks, filters or configuration (or a submodule's). `base_mode` and `size` are optional |
| `read_file(session, path, base: false)` | no | the file's current bytes, or with `base: true` its bytes in the commit the checkout was cloned at; nil when nothing is there. A symlink reads as its target. `path` is always relative and inside the checkout, and `base:` is passed only when true. A backend whose `read_file` takes no `base:` cannot read the checkout commit, so it offers no publishing |
| `start_browser(session, mode:)` | no | `{ mcp_url:, mcp_token: }`, optionally `live_url:`, for a browser of the sandbox's own; `mode` is `:headless` or `:headed`, and `session.browser_launch` carries the rest (see [Browser sessions](./browser-sessions#for-backend-authors)) |
| `stop_browser(session)` | no | true, also when none was running |
| `browser_modes` | no | the modes `start_browser` can run in; a backend without it is asked for either |
| `resume_boot(session, from:)` | no | what `create_sandbox` returns, after re-running a failed boot it kept from the step named `from` (nil for the step that failed). A backend that also takes `boot_config:` is handed the spec to continue with |
| `boot_status(session)` | no | `{ mode:, kind:, failed_step:, kept:, resumable_steps:, steps: [{ name:, status:, started_at:, finished_at:, duration_ms:, detail: }] }`, or nil when it holds nothing for the session. `resumable_steps`, the names `resume_boot` accepts as `from`, is optional |
| `boot_log(session, step:, offset:, limit:, secrets:)` | no | `{ step:, offset:, next_offset:, size:, eof:, text: }`, one page of a step's log scrubbed of the session's secrets and of `secrets`, or nil when the step has no log |

`session` is the `ActionAgent::SandboxSession`, and `handle` is the
`container_name` that `create_sandbox` returned. Calling a verb the backend
does not define raises `SandboxOrchestrator::UnsupportedBackendError`. The
engine's `:local` backend defines `changed_files` and `read_file`,
`start_browser`, `stop_browser` and `browser_modes` (which [Browser
sessions](./browser-sessions) describes), and `resume_boot`, `boot_status`
and `boot_log`, and takes `boot_config:`. It reads the checkout commit object
by object and refuses any object that does not hash to its id, since the
checkout's object store is the sandbox's to write. The `:mock` backend takes
`boot_config:` and records it without the secrets' values, and defines none
of the optional verbs.

### Running against a sandbox without editing the agent

A checkout sandbox is where you try a change: boot a branch, perhaps have a
[Claude Code session](#claude-code-sessions) edit an agent's tools there, and
then see how the agent does with them. For that, a single run can use a
sandbox's runtime without the key being saved on the agent. In a scenario
suite, pick it in **Run against sandbox** next to the models field (the
select lists your ready checkout sandboxes). Every replay of that run is
offered the runtime's tools beside the agent's own, and calls them there, as
if the agent listed `sandbox:<session_id>`. When both serve the same tool
name, the selected sandbox's schema and implementation take precedence;
the model sees that tool only once. If the selected sandbox cannot list its
tools, the run fails instead of falling back to the original server.
The next run, and the agent's
saved `mcp_servers`, are unchanged.

The run records the sandbox it used, and the Runs list, the suite's summary
line and the run report all name it (`against acme/shop@experiment ·
1a2b3c4d`). The API takes the same thing as `sandbox_id`:

| Endpoint | What `sandbox_id` does |
|---|---|
| `POST /api/evaluations/:id/run` | Every replay of this run reaches the sandbox's runtime. The run's `sandbox` (and `selection.sandbox`) is `{ session_id, server_key, repository, repository_ref }` |
| `POST /api/agents/:id/execute`, `POST /api/agents/:id/test` | This runner run reaches it. The run's summary carries `sandbox_id` |

The sandbox must be yours (in your current account, in a multi-tenant
install), an `app_runtime` sandbox, and ready. It must also belong to the
agent's owner, because the runtime is resolved among that owner's sessions,
as a saved key is. Anything else is refused with `422` and a message saying
which (`code: "sandbox_refused"`). A sampling evaluation, which scores
recorded generations rather than running the agent, and a suite a host
adapter replays, cannot run against a sandbox. A queued run whose sandbox has
stopped by the time it starts fails, saying so, rather than replaying without
the tools it was meant to test. The runtime's token is never in a response
or a stored record: runs store only the `sandbox:<session_id>` key.

### Claude Code

Settings -> Integrations also connects **Claude Code**, in one of two ways,
set by `ActionAgent.claude_code_auth`:

- **`:api_key`** (the default). Paste an Anthropic API key (`sk-ant-api03-…`)
  from the [Claude Console](https://platform.claude.com), or one issued
  through a supported cloud provider. It is stored like a provider key
  (encrypted, write-only, masked in the UI) under the provider name
  `claude_code`, and never offered as an agent provider. A checkout backend
  reads `sandbox_session.runtime_environment`, which is
  `{ "ANTHROPIC_API_KEY" => … }`, and gives it to the Claude Code sessions it
  runs in the checkout, and to nothing else: the `:local` backend never puts it
  in the environment of the checkout's setup, manifest or server (see
  [Claude Code sessions](#claude-code-sessions)).
- **`:local_login`**, with the [`:local` backend](#local-checkout-sandboxes)
  only. Sessions run `claude` on the dashboard's machine with that machine's
  own Claude Code login: whatever `claude /login` (or `claude auth login`) set
  up for the dashboard's OS user, in `~/.claude` or the system keychain. The
  dashboard never reads, copies or stores that credential. It only runs
  `claude auth status --json` (at most once a minute) to show whether the
  machine is logged in, and keeps nothing from it but `loggedIn` and the login
  method. No key is asked for. Any other backend refuses Claude Code sessions
  in this mode, since the login cannot leave the machine.

```ruby
ActionAgent.configure do |config|
  config.sandbox_service = :local
  config.claude_code_auth = :local_login
end
```

::: warning Claude subscription tokens are not accepted
The dashboard does not store a Claude subscription login: the token
`claude setup-token` prints (`sk-ant-oat…`) is refused. Anthropic's
[Claude Code legal and compliance terms](https://code.claude.com/docs/en/legal-and-compliance.md)
say that products built on Claude should use API key authentication, and that
third-party developers may not collect, store or route requests through
Claude.ai credentials on their users' behalf. Sign-in to a Claude account must
go through Anthropic's own flow, which is what `:local_login` relies on.

A token stored by an earlier version is never handed to a session: the owner
sees Claude Code as needing an API key (`needs_replacing: true` in
`GET /api/provider_keys`) until they paste one. Delete the stored tokens with
`bin/rails action_agent:claude_code:purge_subscription_tokens`.
:::

`GET /api/sandboxes` reports which mode is in use and whether sessions can
run, never a credential:

| Field | Meaning |
|---|---|
| `claude_code_auth` | `"api_key"` or `"local_login"` |
| `claude_code_connected` | an API key is stored (`api_key`), or this machine is logged in (`local_login`) |
| `claude_code_login` | `{ logged_in, auth_method }`, in `local_login` mode only |
| `code_sessions_supported` | the backend runs sessions, and runs them in this mode |

The dashboard assistant's configuration reports the same under
`connections.claude_code` (`supported`, `connected`, `auth`, `login`).

## Local checkout sandboxes

The engine ships a `:local` sandbox backend, so **Start sandbox** works on a
developer's own machine with no containers. It clones the repository into a
directory under the host app, runs the repository's setup, and boots it as child
processes of the dashboard. Turn it on in the initializer:

```ruby
ActionAgent.configure do |config|
  config.sandbox_service = :local   # or SANDBOX_BACKEND=local
end
```

It needs `git` and `sh` on the dashboard's `PATH`, plus whatever the checkout's
own setup needs (Ruby and Bundler for a Rails app). Claude Code sessions also
need the `claude` CLI, and either an Anthropic API key connected in Settings ->
Integrations or, with `claude_code_auth = :local_login`, the machine's own
Claude Code login (run `claude /login` once as the dashboard's user). See
[Claude Code](#claude-code).

::: warning The local backend runs the owner's code with the dashboard's privileges
The checkout's setup commands, its server and every Claude Code session run as
the dashboard's own OS user, with its filesystem and its network. Environment
sanitizing (below) keeps the dashboard's credentials and database out of their
environment. It does not isolate them: a checkout can read any file that user
can read. Use `:local` on a developer's machine, or on a single-user install
where the person who connects GitHub is the person who runs the dashboard.

It is **off outside development and test** unless you enable it:

```ruby
config.local_sandboxes_enabled = true
```
:::

| Option | Default | What it sets |
|---|---|---|
| `sandbox_service` | `:mock` | The backend: `:mock` (in memory, runs nothing), `:local`, or one registered in `sandbox_backends`. `SANDBOX_BACKEND` overrides it |
| `local_sandboxes_enabled` | unset: on in development and test, off elsewhere | Whether `:local` may run at all |
| `local_sandbox_root` | `Rails.root.join("tmp/action_agent/sandboxes")` | Where each sandbox's workspace lives |
| `local_sandbox_boot_timeout` | `600` (seconds) | The limit on checkout, setup, manifest and server start together, for a checkout booted by its `.activeagents/sandbox.yml`. A [boot spec](#boot-specs) sets its own limit, and a bootstrap never gets less than this one |
| `claude_code_command` | `"claude"` | The Claude Code executable |
| `claude_code_permission_mode` | `"acceptEdits"` | `--permission-mode` for every session |
| `claude_code_max_turns` | `nil` (Claude Code's own default) | `--max-turns` for every session |
| `claude_code_timeout` | `1800` (seconds) | How long a session may run before it is stopped |
| `claude_code_auth` | `:api_key` | How sessions authenticate: the owner's stored API key, or `:local_login` for this machine's own Claude Code login (see [Claude Code](#claude-code)) |

### What a sandbox runs

Each sandbox gets a workspace, `<local_sandbox_root>/<session_id>/`, readable
only by the dashboard's user:

```
app/            the checkout
db/             the sandbox's SQLite databases, when the checkout uses SQLite (see below)
runtime.json    the manifest the checkout wrote (made owner-only, 0600)
state.json      { pid, port, started_at, step_pid, code_sessions: { "<id>" => pid }, boot: { steps, failed_step, kept, ... } }
state.lock      what changes to state.json are serialized on
logs/           checkout, setup, manifest, server and claude-<id> logs; with a boot spec, preflight and one log per step
claude/         CLAUDE_CONFIG_DIR for Claude Code sessions (unused with claude_code_auth = :local_login)
```

Its handle is `local-<session_id>`. Provisioning runs in a background job (a
checkout can take minutes) and does the following, in order:

1. Fetches the ref, one commit deep, into `app/`. The GitHub token is only in
   the environment of that fetch. It never appears on a command line, and it
   is never written to `.git/config`.
2. Reads `.activeagents/sandbox.yml` from the checkout, if there is one, and
   gives the sandbox [databases of its own](#a-database-per-sandbox).
3. Runs each `setup` command.
4. Picks a free port and runs the `manifest` command.
5. Starts the `start` command in its own process group, with its output in
   `logs/server.log`, and records its pid and port in `state.json`.
6. Polls `GET http://127.0.0.1:$PORT<mcp_path>` with
   `Accept: application/json` until it answers `405`, which means the engine
   is mounted and serving (`401` and `200` count too). The answer must come
   from the sandbox's own server: nothing reserves the port between picking
   it and the server binding it, and another process could take it first.
   On Linux the backend checks in `/proc` that the listening socket belongs
   to the server's process group (or to a process carrying the sandbox's
   `ACTION_AGENT_SANDBOX_SESSION_ID`); elsewhere it asks `lsof`. Only where
   neither can say does it send the manifest's token, and then the listener
   must refuse a JSON-RPC `ping` without it (`401`) and accept one with it.

While a step runs, its pid is in `state.json` as `step_pid`, so a terminate
after the dashboard itself died mid-boot still stops it. `state.json` also
records each step as it goes (`GET /api/sandboxes/:session_id/boot` reads
it back; see [Following a boot](#following-a-boot)).

Steps 1 to 6 share `local_sandbox_boot_timeout`. If a step fails, runs out of
time, or the server exits, everything the backend started is stopped. The
sandbox then fails with a message that names the step and ends with the last
lines of that step's log. The GitHub token and the Claude Code API key are
scrubbed from that message. When the sandbox is ready, its MCP server
(`sandbox:<session_id>`) is
`http://127.0.0.1:$PORT<mcp_path>`, with the manifest's token.

### `.activeagents/sandbox.yml`

A checkout says how it boots in an optional `.activeagents/sandbox.yml` at its
root. Every key is optional. The example below shows the default `setup`,
`manifest` and `start`, so a Rails app that mounts this engine needs no file
at all:

```yaml
env:        # extra environment for setup, manifest and server (string values)
  RAILS_ENV: development
setup:      # run once after checkout, in order; default: ["bundle install", "bin/rails db:prepare"]
  - bundle install
  - bin/rails db:prepare
manifest: bin/rails action_agent:sandbox:manifest    # default; must write the manifest JSON to $ACTION_AGENT_SANDBOX_MANIFEST
start: bin/rails server -b 127.0.0.1 -p $PORT        # default; must serve on 127.0.0.1:$PORT and keep running
```

- Every command runs with `sh -c` in the checkout root. A setup command must
  exit 0. `start` must keep running.
- Each command's environment is the sanitized dashboard environment, plus
  `PORT`, `ACTION_AGENT_SANDBOX_MANIFEST` (an absolute path inside the
  workspace) and `ACTION_AGENT_SANDBOX_SESSION_ID`, plus the sandbox's
  [database variables](#a-database-per-sandbox), plus the file's `env`.
  The port is picked after setup, when it was last seen free; nothing holds it
  until the server binds it, so a server that finds it taken fails the boot
  rather than being mistaken for the process that took it (step 6).
  `manifest` and `start` get `PORT`; `setup` does not.
- The GitHub token is never in that environment. The Claude Code API key
  isn't either: only Claude Code sessions get it.
- Unknown keys are ignored. A malformed file fails provisioning, and the
  sandbox's error says what is wrong with it.

**Environment sanitizing.** A sandbox never inherits the dashboard's secrets or
its database. The backend starts from the dashboard's environment as it was
before Bundler set it up (`Bundler.with_unbundled_env`), then drops:

- `DATABASE_URL`, any `*_DATABASE_URL`, `REDIS_URL`, `SECRET_KEY_BASE`,
  `RAILS_MASTER_KEY`, `RAILS_ENV`, `RACK_ENV`, `PORT`,
  `ACTIVE_RECORD_ENCRYPTION_*`, `BUNDLE_GEMFILE`, `BUNDLE_*`, `RUBYOPT` and
  `RUBYLIB`;
- `SSH_AUTH_SOCK`: the checkout's code does not get the developer's SSH
  agent;
- `BUNDLER_*`, and git's repository-location and config variables:
  `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`,
  `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_COMMON_DIR`, `GIT_NAMESPACE`,
  `GIT_PREFIX`, `GIT_QUARANTINE_PATH`, `GIT_CONFIG`, `GIT_CONFIG_GLOBAL`,
  `GIT_CONFIG_SYSTEM`, `GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_PARAMETERS`,
  `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n` and `GIT_CONFIG_VALUE_n`. A git hook
  sets some of them, and they would point the checkout's git at the
  dashboard's own repository or configuration;
- the dashboard's own model-provider and Claude Code settings: every
  `ANTHROPIC_*`, `CLAUDE_*`, `CLAUDECODE`, `OPENAI_*`, `OPEN_AI_*`,
  `OPENROUTER_*`, `OPEN_ROUTER_*` and `OLLAMA_*` variable. A dashboard run from
  inside Claude Code exports its own session's variables and an
  `ANTHROPIC_BASE_URL`. A session that inherited them would join that session,
  and the base URL would send the owner's credential elsewhere. A Claude Code
  session gets exactly the variables the backend sets (below);
- every variable whose name looks like a secret: it contains `SECRET`,
  `TOKEN`, `PASSWORD`, `PASSWD`, `PASSPHRASE`, `API_KEY`, `APIKEY`,
  `PRIVATE_KEY`, `CREDENTIAL`, `ACCESS_KEY` or `WEBHOOK`, or ends in `_KEY`,
  `DSN`, `_PASS`, `_PWD` or `_PAT` (`DB_PASS`, `MYSQL_PWD`, `LOCKBOX_MASTER_KEY`,
  `SENTRY_DSN`, `GITHUB_PAT`; a bare `PASS`, `PWD` or `PAT` counts too);
- every variable whose value holds a URL with credentials in it, whatever its
  name: a password (`redis://:secret@cache:6379`) or a token as the username
  alone (`https://ghp_x@github.com`). Any `user@` in a URL counts.

Everything else is kept: `PATH`, `HOME`, `LANG`, `TMPDIR`, proxy and CA
variables, and rbenv, mise and asdf settings. Processes are spawned with
exactly that environment (`unsetenv_others: true`), so nothing else leaks
through. Because `RAILS_ENV` is dropped, a Rails checkout boots in development
unless its `env` sets it. A checkout that needs a key of its own sets it in
`env`, or reads it from its own credentials.

### A database per sandbox

A checkout's `config/database.yml` usually names a fixed development
database. For a checkout of the app you run the dashboard from, that is
*your* development database, and its `db:prepare` would migrate it. So every
sandbox boots on databases of its own, set through the variables Rails
merges over `database.yml`: `DATABASE_URL` for the `primary` database, and
`<NAME>_DATABASE_URL` for any other, as for the `queue` and `cache`
databases Rails 8's Solid Queue and Solid Cache add
(`QUEUE_DATABASE_URL`, `CACHE_DATABASE_URL`).

The backend reads the adapter and database name of each entry in the
checkout's `config/database.yml`, for the environment the checkout boots in
(`RAILS_ENV` from `env`, or `development`):

| Adapter | Each database becomes | When the sandbox is terminated |
|---|---|---|
| `sqlite3` | `sqlite3:<workspace>/db/development.sqlite3` (`development_<name>.sqlite3` for the others) | removed with the workspace |
| `postgresql`, `postgis` | `postgresql:///<database>_sandbox_<first 8 of the session id>` | dropped by the checkout's Rails database tasks, restricted to recorded sandbox databases |
| `mysql2`, `trilogy` | `mysql2:///<database>_sandbox_<first 8 of the session id>` | the same |
| anything else | left as configured, and logged | — |

- The URLs name only the database. Rails merges a URL over the entry, so the
  host, port, user and password stay what `database.yml` or the environment
  (`PGHOST`, `PGPORT`, `PGUSER`) say. `PGPASSWORD` is a secret the
  sanitizing drops: use `~/.pgpass`, or set it in `env`.
- A replica (`replica: true`) reads the sandbox database of the writer with
  the same adapter and literal database name, regardless of YAML order.
  If the writer is ambiguous or its identity depends on ERB, boot refuses
  rather than guessing; set the replica's `<NAME>_DATABASE_URL` in `env`.
  An entry with
  `database_tasks: false` is a database the app does not manage, and is left
  alone. So is one given as a `url:`, which Rails lets no variable override.
- `SKIP_TEST_DATABASE=1` is set too: without it, `db:prepare` in development
  also prepares the test database, which is still yours.
- Claude Code sessions get the same variables, so a `bin/rails db:migrate`
  a session runs lands in the sandbox's database.
- The drop runs after the server has stopped, in the recorded Rails
  environment, and is given 60 seconds. A `bin/rails runner` script selects
  only the named database URLs recorded at boot before invoking Rails'
  protection checks and drop tasks. Overrides, new configurations and
  configurations whose resolved URL changed are excluded. Old sandbox
  state without this explicit list is not dropped automatically. Cleanup is
  best effort: a failed drop is logged and the sandbox goes anyway.
  A boot that fails uses the same restricted cleanup.
- `database.yml` is never evaluated in the dashboard. Its ERB tags are
  blanked out and the rest is read as plain YAML. When that does not parse,
  the first `adapter:` line is taken as the primary database's. The file is
  read only at `config/database.yml` in the checkout root: an app nested
  deeper sets its own (the SQLite path of this repository's `test/dummy` is
  relative, so already inside the checkout).
- `logs/setup.log` begins with a `# sandbox database:` line for each decision.

To choose a database yourself, set its variable in `env`; whatever `env`
sets is left alone, and never dropped:

```yaml
env:
  DATABASE_URL: postgresql:///shop_experiments
```

**Known limits of the local backend.**

- **Code reloading.** In development, Active Job's default async adapter runs
  jobs inside the web process, and a reloading app holds the reloader while a
  job runs. A checkout boot (up to `local_sandbox_boot_timeout`) or a Claude
  Code session (up to `claude_code_timeout`) can delay code reloading until it
  finishes. Run jobs in a separate worker (Solid Queue, for example) if that
  gets in the way.
- **Filters.** When a checkout's git config defines filter drivers, which a
  session could add, the session's diff is not recorded rather than running
  their commands. The backend's own git commands also run with
  `core.fsmonitor=false` and `core.hooksPath=/dev/null`, so a filesystem
  monitor or hook the session set in `.git/config` does not run either.
- **macOS.** Without `/proc`, the backend identifies its processes by their
  start time from `ps` (read in UTC, so a restart under another `TZ` still
  recognizes them), and never signals a pid it cannot identify. A terminate
  that finds such a process still alive keeps the workspace and its
  `state.json`, logs it, and reports the sandbox as not released, so the
  reaper tries again.
- **Processes that leave the group.** Stopping a sandbox signals its process
  groups. A process that calls `setsid` (or otherwise daemonizes) leaves its
  group and is not reached that way. On Linux the backend also stops every
  process whose environment carries the sandbox's
  `ACTION_AGENT_SANDBOX_SESSION_ID`, but one that also rewrote its
  environment (a long process title does) escapes both, and keeps running
  after the sandbox is stopped. Without `/proc`, any process that called
  `setsid` does.

This repository boots its own dummy app this way. Its
[`.activeagents/sandbox.yml`](https://github.com/activeagents/activeagent/blob/main/.activeagents/sandbox.yml)
shows a nested app, and a Gemfile that isn't at the root.

### The manifest task

The manifest tells the backend where the booted app's MCP facade answers and
which bearer token opens it:

```json
{ "mcp_path": "/activeagents/mcp", "mcp_token": "aa_..." }
```

The engine ships `bin/rails action_agent:sandbox:manifest`, so every app that
mounts it has the task. The task finds the engine's mount in the app's routes
and writes the manifest to `$ACTION_AGENT_SANDBOX_MANIFEST`. When that
variable is unset, it prints the manifest instead. The token belongs to a
dashboard API key named "Checkout sandbox runtime", in the checkout's own
database. The first run creates it, and later runs reuse it, so a sandbox
that boots again doesn't add a key. If the engine is not mounted, the task
exits non-zero with
`action_agent:sandbox:manifest: ActionAgent::Engine is not mounted in this app's routes`.

The task also mirrors the app's agent classes into the checkout's dashboard
with `ActionAgent::AgentSync`, so the facade serves a `run_<slug>` tool for
each. It syncs every `ActiveAgent::Base` subclass defined under `app/agents`,
except `ApplicationAgent` and abstract classes, and a re-run updates them in
place. A class that cannot be synced (one with no provider or model, say) is
reported on stderr, and the rest are synced.

The key and the synced agents each take an owner of the class their model is
owned through. API keys are owned through `account_class` when it is set and
`user_class` otherwise, and agents the other way round, so an app that
configures both gives the key an account and the agents a user. For each of
the two:

- With no owner class, it has no owner, and the key reaches every agent.
- With exactly one record of its owner class, it belongs to that record. A key
  minted earlier without an owner takes it.
- With none or several, the sandbox cannot tell whose it would be. A key has
  no owner and reaches no agents over MCP. No agents are synced, and the task
  says so on stderr.

The facade serves the key the agents `ActionAgent.agents_for` gives its
owner, as the dashboard does. When keys and agents are owned through
different classes, that takes the host's `agent_scope_resolver`.

When the sandbox cannot give the agents an owner, and for an app that isn't
Rails, `manifest` can be any command that writes the JSON. `mcp_path` must
start with `/`, and `mcp_token` is a string or `null`.

### Bootstrapping a checkout without the engine

A Rails app that doesn't bundle `actionagent` can still boot in a sandbox:
the backend installs the engine into the checkout first. This needs a
backend that takes a [boot spec](#boot-specs), as `:local` does.
`POST /api/sandboxes` with `sandbox_type: "app_runtime"` takes three options
for it:

| Option | Default | What it does |
|---|---|---|
| `bootstrap` | `"auto"` | `"auto"` bootstraps the checkout when its `Gemfile.lock` locks no `actionagent` and its `.activeagents/sandbox.yml`, if it has one, names no `manifest`. Any other checkout boots as its `sandbox.yml` says. `"always"` bootstraps the checkout whatever its lock says, and is refused with `422` when the backend cannot take a spec. `"never"` boots it as its `sandbox.yml` says. `true` and `false` mean `"always"` and `"never"` |
| `start_url` | `"/"` | A path on the app that must not answer `5xx` once the MCP facade answers |
| `keep_on_failure` | `false` | Keep a failed boot's workspace and databases, so it can be [resumed](#keeping-a-failed-boot) |

Before any of the checkout's commands runs, a preflight reads its
`Gemfile.lock` and refuses a checkout, naming the requirement, when:

- there is no `Gemfile.lock` at its root;
- it locks Ruby older than 3.2 (the lock's `RUBY VERSION`, or
  `.ruby-version` when the lock pins none);
- it locks no `railties`, or `railties` older than 7.2;
- there is no `config/application.rb` at its root.

Then it runs these steps in the checkout, each with a log and a timeout of
its own:

| Step | Command | Timeout | Runs when |
|---|---|---|---|
| `bundle_config` | `bundle config set --local frozen false` | 60 s | always |
| `bundle_install` | `bundle install` | 900 s | always |
| `add_framework` | `bundle add activeagent --git … --ref …` (or `--path …`) `--skip-install` | 300 s | the engine comes from git or a path, and the lock has no `activeagent` |
| `add_engine` | `bundle add actionagent --version "~> <ActionAgent::VERSION>"`, or the same `--git`/`--ref` or `--path` | 900 s | the lock has no `actionagent` |
| `install_framework` | `bin/rails generate active_agent:install --skip` | 300 s | the lock has no `activeagent` |
| `install_engine` | `bin/rails generate action_agent:install --skip` | 300 s | the lock has no `actionagent` |
| `javascript_build`, `css_build`, `tailwindcss_build` | `bin/rails javascript:build`, `css:build`, `tailwindcss:build` | 600 s each | the app defines the task (from `bin/rails -T -A`, listed once per boot) |
| `db_prepare` | `bin/rails db:prepare` | 900 s | always |
| `manifest` | `bin/rails action_agent:sandbox:manifest` | 300 s | always |
| `start` | `bin/rails server -b 127.0.0.1 -p $PORT` | 300 s | always |

"The lock" is the checkout's `Gemfile.lock` as it was checked out.

- The engine installed is the dashboard's own. From rubygems.org that is
  `~> <ActionAgent::VERSION>`, which brings `activeagent` with it. When the
  dashboard bundles the engine from git or a path, it is the same git
  revision or path, read from the dashboard's `Gemfile.lock`. A path only
  works on `:local`. A git URL with credentials in it is refused rather than
  written into the checkout's Gemfile: an explicit bootstrap fails, and
  `"auto"` boots without one.
- With `--skip`, the generators keep every file that already exists. A
  checkout that already has `config/active_agent.yml` or
  `app/agents/application_agent.rb` keeps them byte for byte.
- The whole boot, checkout included, has 1800 seconds, or
  `local_sandbox_boot_timeout` on `:local` when that is longer. Each step's
  own timeout bounds it within that, and a step that runs out names itself
  and the limit.
- Once the MCP facade answers, `GET <start_url>` on the sandbox's own server
  must answer something other than a `5xx`. A redirect to sign in, or a
  `404`, passes. A `5xx` fails the `start` step with the status and the end
  of the server's log.
- The sandbox's own settings (its port, databases, manifest path and session
  id) are environment variables, so nothing sandbox-only is written into the
  checkout. After a bootstrap, `git status` shows only what `bundle add`, the
  generators and `db:prepare` wrote. `bundle config set --local` writes
  `.bundle/config`, which Rails' default `.gitignore` ignores.

### Boot specs

What a bootstrap runs is a boot spec, `ActionAgent::SandboxBootSpec`: data
the engine builds and hands the backend as
`create_sandbox(session, boot_config:)`. `SandboxBootSpec.bootstrap` builds
the one above. `#to_h` is plain JSON, so a backend that boots somewhere else
(a container's own boot script) reads the same thing:

```json
{
  "kind": "bootstrap",
  "apply": "always",
  "preflight": true,
  "steps": [
    { "name": "bundle_config", "command": "bundle config set --local frozen false", "timeout": 60 },
    { "name": "add_engine", "command": "bundle add actionagent --version \"~> 1.9.0\"", "timeout": 900, "unless_locked": "actionagent" },
    { "name": "css_build", "command": "bin/rails css:build", "timeout": 600, "if_task": "css:build" }
  ],
  "env": {},
  "secrets": {},
  "manifest": { "command": "bin/rails action_agent:sandbox:manifest", "timeout": 300 },
  "start": { "command": "bin/rails server -b 127.0.0.1 -p $PORT", "timeout": 300 },
  "start_url": "/",
  "keep_on_failure": false,
  "timeout": 1800,
  "engine": {
    "activeagent": { "source": "rubygems", "version": "1.9.0" },
    "actionagent": { "source": "rubygems", "version": "1.9.0" }
  }
}
```

- A step with `unless_locked` is skipped when the checkout's lock, as checked
  out, locks that gem. One with `if_task` is skipped when the app defines no
  such Rake task.
- With `"apply": "without_engine"` (what `bootstrap: "auto"` sends), a
  checkout that bundles the engine, names a `manifest` in its `sandbox.yml`,
  or has no `Gemfile.lock` boots as it would without a spec, except that the
  spec's `secrets` are added to its `sandbox.yml` env. A backend whose
  `create_sandbox` takes no `boot_config:` is not handed such a spec, and
  boots as it always has. One with `"apply": "always"` is refused for that
  backend instead.
- `secrets` are environment for the steps, manifest and server, like `env`,
  and are scrubbed from every log and message the backend produces. They
  travel in memory only. The backend records the spec without their values
  (`secret_names` lists the names), and they never reach a job argument, the
  checkout's git fetch or a Claude Code session. A secret may not set `PORT`,
  `DATABASE_URL`, `*_DATABASE_URL` or `ACTION_AGENT_SANDBOX_*`, nor anything
  that changes how Ruby, Bundler, Node or git load code: `RUBYOPT`,
  `RUBYLIB`, `LD_PRELOAD`, `DYLD_*`, `BUNDLE_*`, `GIT_*`, `PATH` and
  `NODE_OPTIONS`.

### Following a boot

| Endpoint | Returns |
|---|---|
| `GET /api/sandboxes/:session_id/boot` | `{ boot, resumable, logs }`. `boot` is the backend's `boot_status`: each step with its `status` (`pending`, `running`, `succeeded`, `failed` or `skipped`), times and a scrubbed `detail`. It is null for a backend that reports no steps. `resumable` says whether `POST …/resume_boot` would be accepted, and `logs` whether step logs can be read |
| `GET /api/sandboxes/:session_id/boot_log?step=NAME&offset=N&limit=N` | One page of that step's log as `{ step, offset, next_offset, size, eof, text }`, 64 KB by default and 1 MB at most. Read on from `next_offset` until `eof`. A page ends at a line break, and its text is scrubbed of the checkout token and the Claude Code credential |
| `POST /api/sandboxes/:session_id/resume_boot` | See [Keeping a failed boot](#keeping-a-failed-boot) |

On `:local`, each step's output is scrubbed a line at a time on its way to
its log. The server outlives the job that started it, so its output goes to
`logs/server.log` as the server prints it, and is scrubbed when read.

### Keeping a failed boot

With `keep_on_failure`, a boot spec that fails stops everything it started
but keeps the workspace and the sandbox's databases. `state.json` names the
step that failed (`failed_step`). The sandbox fails as usual, with the step
and its log tail in its error.

`POST /api/sandboxes/:session_id/resume_boot`, optionally with
`{ "from": "<step>" }`, continues the boot from the step that failed, or
from the one named. It runs on the same checkout and databases: nothing is
cloned again, and no earlier step runs again. The sandbox is `provisioning`
again and is polled as after a create, and a resume that fails is kept
again. A resume is refused with `422` unless the sandbox is a failed checkout
that has not expired, kept its boot, and has a backend that implements
`resume_boot`. A `from` that is not among the boot's `resumable_steps` is
refused with `422` too, and the sandbox keeps the error its boot failed
with. On `:local` those are the spec's steps, its manifest and its start.
The checkout and the preflight never run again. A resume needs execution to
be enabled and answers to the execution quota, but is not counted as another
execution. The backend keeps the spec without its secrets' values, so
`SandboxOrchestrator#resume_boot` takes the spec again (`boot_config:`) for a
boot that had secrets.

A stop (`DELETE`) removes a kept workspace like any other, and the reaper
releases one once its sandbox has expired (see
[Stopping and reaping](#stopping-and-reaping)).

### Stopping and reaping

- **Stop** on a sandbox (`DELETE /api/sandboxes/:session_id`) expires it and
  terminates it.
- Terminating sends `SIGTERM` to the server's process group, to a boot step
  still running and to any running Claude Code session. After about 10
  seconds it sends `SIGKILL`, then removes the workspace.
- A pid is signalled only if that workspace's `state.json` recorded it, and
  only while it is still the process recorded there (by its start time). A
  sandbox that is already gone counts as stopped. One whose recorded process
  is alive but cannot be stopped or identified is kept, with its handle, and
  the reaper tries again.
- An `app_runtime` sandbox expires 2 hours after it is created. Other sandbox
  types expire after 15 minutes.

Nothing reaps expired sandboxes on its own. Schedule the reap task:

```bash
bin/rails action_agent:sandbox:reap   # prints "Expired N sandbox session(s)"
```

It expires every session that is past its expiry and still pending,
provisioning, ready or running, and terminates each one through
`ActionAgent::SandboxCleanupJob`. It also retries sessions whose earlier
terminate failed: those that still hold a handle and, for a backend that
derives a sandbox's handle from its session (`:local` does), expired
`app_runtime` sessions with no handle that changed within the last day (at
most 100 per run). A checkout whose boot never recorded a handle may still
have processes, and nothing else records that a terminate of it failed. For
such a backend it also terminates failed `app_runtime` sessions whose expiry
passed within the last day, releasing a boot kept with `keep_on_failure`;
they stay failed, so their error can still be read. Run it from cron, or as
a Solid Queue recurring task:

```yaml
# config/recurring.yml
development:
  reap_sandboxes:
    command: "ActionAgent::SandboxCleanupJob.cleanup_expired!"
    schedule: every 5 minutes

production:
  reap_sandboxes:
    command: "ActionAgent::SandboxCleanupJob.cleanup_expired!"
    schedule: every 5 minutes
```

The file Rails and the Solid Queue installer generate is keyed by environment
(it starts with `production:`). Solid Queue reads only the current
environment's key when the file has one, so a top-level `reap_sandboxes:`
never runs there. Add the entry under each environment the file names.

A sandbox runs in its own process groups, so stopping the dashboard doesn't
stop its sandboxes. After a restart, `state.json` is how the dashboard finds
them again. Provisioning, Claude Code sessions and cleanup run as Active Job
jobs, and **Cancel** signals a session from the web process. Run the
dashboard and its job workers on one machine, as one user, so they share the
workspaces.

### Codex sessions

The **Code sessions** panel also offers **Codex** when the sandbox backend
advertises that runner. The `:local` backend supports both runners. Install
the official Codex CLI on the dashboard/worker machine (`npm install -g
@openai/codex`), connect an OpenAI API key under **Settings → Integrations →
Codex**, and select Codex in a ready checkout's **Agent** menu. The key is
stored as a write-only, owner-scoped connection, separate from the OpenAI
agent-builder key. API usage is billed to the key's project.

Codex runs with `codex exec --json --ephemeral --sandbox workspace-write
--config 'approval_policy="never"' --color never -`. The prompt is sent on
stdin. The selected connection supplies `CODEX_API_KEY`, and `CODEX_HOME`
points to the sandbox's own configuration directory. Inherited `CODEX_*`
and `OPENAI_*` settings are removed. The CLI's workspace-write sandbox stays
enabled; a host that cannot support it must be fixed rather than bypassing
the CLI sandbox. The dashboard's local backend still requires trusted code
and the same host isolation described above.

The model defaults to Codex's choice; **Other…** accepts an explicit model
id. Native JSONL events are stored and rendered with command output, the
final response, token usage and the checkout diff. A successful terminal
event and a zero process exit are both required. Cancellation and the
one-session-per-checkout limit are shared with Claude Code.

`codex_command` defaults to `"codex"`; `codex_timeout` defaults to 1800
seconds. API clients send `runner: "codex"` to the existing code-session
endpoint. Omitting `runner` keeps the Claude Code behavior. Existing
installations must rerun `rails generate action_agent:install` and
`rails db:migrate` to add runner identity to existing sessions; old sessions
remain `claude_code`.

Custom backends opt in with `code_runners`, returning supported names such
as `%w[claude_code codex]`. Backends without that method retain their existing
Claude Code support; they are never assumed to support Codex. Codex support
was checked against CLI 0.159.2. Cloud/Incus hosts must implement the checkout
and code-session backend contract before either runner can execute there.

### Claude Code sessions

When a sandbox is **ready**, its card in Settings → Integrations shows a
Claude Code panel. **Run Claude Code** stays disabled until Claude Code can
run: an Anthropic API key is connected, or, with `claude_code_auth =
:local_login`, this machine's Claude Code is logged in (see
[Claude Code](#claude-code)). Write a prompt, and the dashboard
runs Claude Code headless in the checkout. The **Model** select next to it
picks what the session runs on: *Default (Claude Code's own)* sends no
model, `sonnet`, `opus` and `haiku` are Claude Code's aliases, and *Other…*
takes a full model id (`claude-sonnet-4-5`). The panel remembers the last
choice in this browser. Each session in the list, and the open one, shows
its model. The panel shows each event as it arrives:

- the assistant's text;
- each tool call and its result;
- the final result line, with turns, cost and duration.

When the session finishes, the panel shows the checkout's `git diff`, with new
files included. **Cancel** stops a running session: `SIGTERM`, then `SIGKILL`
if Claude Code has not exited about 10 seconds later. A cancelled session is
marked cancelled at once, but its events and diff are recorded until Claude
Code has stopped. Its `diff_pending` stays `true` until then, and the panel
keeps polling. A session that never ran (cancelled in the queue, or before
Claude Code started) settles with no diff and `diff_pending: false`.

Only one session runs per sandbox at a time. Each one counts as an execution:
`execution_enabled` must be on, and the execution quota applies. Sessions are
stored in `active_agent_code_sessions`. An existing install gets that table by
running `rails generate action_agent:install` and `rails db:migrate` again.
The API offers the same actions:

- `GET` and `POST /api/sandboxes/:session_id/code_sessions` (`prompt`, and
  an optional `model`);
- `GET …/code_sessions/:id?after=N`, which returns events from index N, and
  the diff once the session has finished;
- `POST …/code_sessions/:id/cancel`.

The `:local` backend runs:

```bash
claude -p --output-format stream-json --verbose \
  --permission-mode acceptEdits --no-session-persistence
```

It adds flags as needed:

- `--permission-prompts none` when the installed CLI supports it;
- `--max-turns N` when `claude_code_max_turns` is set;
- `--model M` when the session names a model.

The prompt goes in on standard input, never on the command line. The session
runs in the checkout, in its own process group. Its environment is the
sanitized one, plus:

- with `claude_code_auth = :api_key`, the owner's key as `ANTHROPIC_API_KEY`,
  and `CLAUDE_CONFIG_DIR` set to the sandbox's own `claude/` directory;
- with `:local_login`, no credential and no `CLAUDE_CONFIG_DIR`: Claude Code
  reads the dashboard user's own configuration and login from `HOME`, which
  the sanitized environment keeps. The dashboard's own `CLAUDE_*` and
  `ANTHROPIC_*` variables are still dropped, so a session never picks up a key
  or a base URL from the dashboard's environment. The user's `~/.claude`
  settings (hooks, MCP servers, permissions) apply to these sessions too;
- `DISABLE_AUTOUPDATER`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` and
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, each set to `1`.

A session still running after `claude_code_timeout` is stopped and fails. The
backend scrubs the checkout token and the Claude Code API key from the
recorded events and the diff. A session keeps at most 1,000 events, and a diff
of at most 500 KB.

**Permission mode.** Sessions run in `acceptEdits` mode unless you set
`claude_code_permission_mode`. In that mode, Claude Code may edit files in the
checkout and run filesystem commands. Nobody is there to answer a permission
prompt, so anything else that would ask is denied. `plan` keeps sessions
read-only. Avoid `bypassPermissions`: it lets a session run any command as the
dashboard's user.

## Session timelines

Every conversation, run and evaluation scenario replay can be read as a
timeline: message, LLM, tool and browser lanes on one time axis. The lanes are
derived when the timeline is read, from the run log, the conversation's
messages and generations, and the stored telemetry spans, so a session needs
no recording to have one.

| Endpoint | The timeline of |
|---|---|
| `GET /api/sessions/context/:id/timeline` | a conversation (`AgentContext`) |
| `GET /api/sessions/run/:id/timeline` | a run (`AgentRun`) |
| `GET /api/sessions/scenario_result/:id/timeline` | the run that replayed an evaluation scenario |
| `GET /api/session_recordings/:id/timeline` | a recording: its browser lane, with the lanes of its conversation or run |

The response carries `session` (its runs, conversations and trace ids),
`lanes` (`message`, `llm`, `tool`, `browser`, each in time order) and
`recordings`. Every entry has an `id`, a `start` (ISO 8601 with
milliseconds), a `duration_ms` and a `trace_id`, null when unknown. Each lane
holds its earliest 2,000 entries, and `session.truncated` is true when any
lane had more.

A conversation's timeline adds the recordings linked to the conversation or
to one of its runs. A run's timeline, and a scenario result's, adds only the
recordings linked to that run, so a recording made for a whole conversation
appears in the conversation's timeline and not in its runs'.

rrweb events are not in the timeline. Read them from
`GET /api/session_recordings/:id/events`, which returns the recording's event
rows in time order, a page at a time:

| Parameter | Meaning |
|---|---|
| `kind` | the kinds to return, comma separated (`kind=console,marker`); `rrweb` when absent |
| `limit` | rows per page, 20 by default and at most 100; a page also ends after about 4 MB of events |
| `after` | the `next_after` of the previous page |

The response carries `events` (the rows, each with its `events`), `has_more`
and `next_after`.

A timeline reaches runs, conversations and traces only through ids the server
set: a recording's run and conversation, and a run's trace id. Each is looked
up among what the caller owns, and a session the caller does not own answers
404. Ids inside recorded events are shown, never followed.

What a browser tool call typed (`browser_type` text, `browser_fill_form`
values and `browser_handle_dialog` prompt text) is masked in that call's
arguments and result. A later call whose result shows the value, such as a
snapshot of the filled field, is not masked. Timelines, and events other than
rrweb, never carry a `cookies`, `local_storage` or `session_storage` key.
rrweb events are returned as the browser recorded them, so that they replay.

### Recording events

A recording stores what a browser recorded as `recording_events`, by kind:

| Kind | Written by |
|---|---|
| `rrweb`, `console`, `marker` | a browser, through the ingest endpoint below |
| `action` | the engine, for each browser tool call an agent makes |
| `human_input` | reserved for input relayed while a person drives the browser |

A browser posts a batch to `POST /api/session_recordings/:id/events`:

```json
{
  "sent_at": 1767225600000,
  "recording_events": [
    { "kind": "rrweb", "timestamp": 1767225599500, "data": { "type": 3, "data": {} } },
    { "kind": "console", "timestamp": 1767225599800, "data": { "level": "error", "message": "boom" } }
  ]
}
```

`sent_at` is the client's clock when it sent the batch. The server adds
receive time minus `sent_at` to every timestamp, so a client with a wrong
clock is still stored in server time. The engine adds `recording_events` to
the app's `filter_parameters`, so a batch's content never reaches the request
log. A batch authenticates with either:

- the recording's ingest token, as `Authorization: Bearer <token>`.
  `SessionRecording#issue_ingest_token!` returns it and stores only its
  digest. It is accepted for that recording alone, cannot read anything back,
  and stops working when it expires (two hours by default), when the
  recording completes, or when the recording's sandbox stops. A batch sent
  this way may be gzipped, with `Content-Encoding: gzip`, as a sandbox's
  browser sends it; it is inflated no further than `batch_bytes`;
- a dashboard session with its CSRF token, for a recording the user owns.

A batch is stored whole or not at all. It answers 422 when it holds a kind a
browser may not write, when an event's `timestamp` is more than 24 hours
before `sent_at` or more than a minute after it, or when it nests more than
512 levels deep. It answers 413 (`code: "recording_limit"`) when it is over a
cap, counting its events in the recording's `dropped_event_count`. The caps
default to:

```ruby
ActionAgent.configure do |config|
  config.recording_limits = {
    batch_events: 1_000,
    batch_bytes: 1.megabyte,
    recording_events: 100_000,
    recording_bytes: 100.megabytes
  }
end
```

A dashboard session's batch is also parsed by Rails as request parameters,
which refuses JSON nested more than 100 levels deep: an rrweb snapshot of a
page whose elements nest about 47 deep. A recorder of arbitrary pages should
post with an ingest token.

When an agent calls one of the Playwright browser tools in
`ActionAgent::MCPRecordingMiddleware::PLAYWRIGHT_TOOLS` (navigating, clicking,
typing, filling forms, taking snapshots and the like), the call is stored as
an `action` event on its run's recording, which the first call starts with
`source: "agent"`. Listing console messages or network requests is not
recorded. Typed values are masked and the
owner's credentials are scrubbed before anything is stored. A failure to
record is logged and leaves the tool's result unchanged.

Each row's payload is gzip JSON, kept in the row up to 64 KB compressed and
attached through Active Storage above that when the app has it.

## Projects

A project is a repository the dashboard boots in a checkout sandbox and
evaluates an agent against, whether or not the repository uses ActiveAgent.
It keeps what every boot needs: the ref, the [start URL](#bootstrapping-a-checkout-without-the-engine),
the secrets the app reads from its environment, and the agent and evaluation
it tests the booted app with. Projects are under **Projects** in the sidebar.

### Before the first project

`GET /api/projects/capabilities` is the New Project page's checklist. Each
item says whether it holds and, when not, the configuration line or step that
fixes it. Creating a project is refused while a blocking item fails.

| Item | Blocking | Holds when |
|---|---|---|
| `sandbox_backend` | yes | the backend runs checkouts. The `:mock` backend runs nothing, so it is refused outside the test environment |
| `local_sandboxes` | yes | `:local` only: `ActionAgent.local_sandboxes_enabled?` |
| `boot_spec` | yes | the backend's `create_sandbox` takes [`boot_config:`](#boot-specs), which is how a project's bootstrap and secrets reach it |
| `execution` | yes | agent execution is enabled |
| `github` | yes | a GitHub App or OAuth app is configured. The item names the exact callback URL to register |
| `github_connection` | yes | the owner connected GitHub |
| `model_credentials` | no | a provider has credentials for the project's agent |
| `browser` | no | browser sessions, not available yet |
| `code_runners` | no | the backend runs Claude Code or Codex sessions |

### Picking a repository

Before any sandbox exists, `GET /api/projects/preflight?repository=owner/name`
reads the repository through GitHub's contents API: `Gemfile.lock`,
`.ruby-version`, `config/application.rb`, `config/database.yml` and the
`Gemfile`. It applies the bootstrap preflight's requirements and answers
`supported` (the repository bundles the engine), `bootstrap` (the sandbox
installs it) or `unsupported`, with the reason. Services a sandbox does not
run (Redis, Sidekiq, Elasticsearch) and database adapters a local sandbox
cannot provision are warnings. A repository the connection has not selected
is looked up by name, which also reaches repositories past the listing's
500-repository cap.

The files are read at the commit the ref names (`ref`, or the default
branch), and the report is kept in `Rails.cache` for that commit: checking
the repository again, or creating the project, costs one GitHub call until
the ref moves. A ref that names no commit is `unsupported`.

Reading a repository the connection has not selected, whether to check it,
to discover its secrets or to create a project from it, needs `:manage_github`
(see [Permissions](#permissions)). The connection's token can be one
member's, reaching that member's own repositories, so only the selection is
open to every member. The `403` comes before GitHub is asked, so it does not
tell whether the repository exists. Creating a project from such a repository
selects it. Before a project is created, `ActionAgent.quota_checker` is asked
about `:project`, and a denial answers `402`.

### Secrets

`GET /api/projects/discover_secrets?repository=owner/name` lists the
environment variables the repository expects, without a model call, so the
New Project page asks for all of them in one form:

- every `NAME=` line of `.env.example` and `.env.sample`;
- the `secrets:` key of `.activeagents/sandbox.yml`, a list of names or a
  mapping of names to descriptions. It holds names only, never values;
- `ENV.fetch("NAME")` and `ENV["NAME"]` call sites in the Ruby, YAML and ERB
  files under `config/` and `lib/`, at most 40 files. `ENV.fetch` with no
  default marks the variable as required.

Only files the commit lists are read, and the result is cached per commit
like the preflight. A ref that names no commit answers `404`.

```yaml
# .activeagents/sandbox.yml
secrets:
  STRIPE_SECRET_KEY: Test-mode key for checkout
  MAILER_PASSWORD: SMTP password
```

A project's secrets are `ActionAgent::ProjectSecret` records, encrypted at
rest. The API returns their names, sources, who set them and when, never
their values.

| Endpoint | What it does |
|---|---|
| `GET /api/projects/:id/secrets` | The Environment tab's list |
| `PUT /api/projects/:id/secrets` | Sets a list of `{ name, value }` or `{ name, source: "organization_key", consent: true }`, all or none |
| `PUT /api/projects/:id/secrets/:name` | Replaces one value |
| `DELETE /api/projects/:id/secrets/:name` | Removes one |

- Setting, replacing and removing need `:manage_project_secrets`. A secret
  that uses the organization's provider key needs `:manage_credentials` as
  well: the repository's code can read a key the provider keys API never
  returns.
- A secret may not take a name the sandbox sets or one that changes how code
  is loaded, the same names a [boot spec's](#boot-specs) `secrets` refuse.
  Such a name answers `422`.
- For `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY`, a
  secret can use the organization's stored provider key instead of a value.
  It needs `consent: true`, since the repository's code can read the key. The
  key is read when the sandbox boots and never copied into the project, and a
  secret is refused when the owner stores no such key.
- Saving a live-mode key (`sk_live_`, `rk_live_`), a value shorter than 8
  characters (which logs cannot mask) or `RAILS_MASTER_KEY` returns a
  warning, and the form shows it before saving.
- Values reach only the steps that run the repository's code (setup,
  manifest and start), never the checkout's git fetch or a Claude Code or
  Codex session. Each value, with its URL-encoded and Base64 forms, is
  scrubbed from provision errors, step logs, boot status and code-session
  events.
- Whoever can push to the project's ref can read its secrets once it boots,
  so changing the ref needs what setting each secret needs.
  `PATCH /api/projects/:id` with a new `default_ref` (empty for the
  repository's default branch) is preflighted like a new repository and
  refused when unsupported. It stops the sandbox booted from the old ref, and
  the next boot checks the new one out. A ref whose lock lacks the engine is
  evaluated with the App assistant. Changing `name` or `start_url` needs
  nothing.
- Deleting a project that has secrets (`DELETE /api/projects/:id`) needs
  `:manage_project_secrets`.

### Booting

`POST /api/projects/:id/boot` returns the project's sandbox: the current one
while it boots or serves, the current one resumed from the step that failed
when its failed boot was kept, or a new one. A project boots from a
`without_engine` bootstrap spec with `keep_on_failure`, carrying its secrets:
a repository that lacks the engine is bootstrapped, and one that bundles it
boots as its `sandbox.yml` says, with the secrets added to its env.

On `:local`, the first boot of each project answers `409` with
`"This runs <owner/repo>'s code on this machine as <user>."`. The same
request with `confirm: true` boots it, and later boots do not ask again.

`GET /api/projects/:id/boot` returns the project, its boot's steps with their
status and elapsed time, and the scrubbed tail of the step that failed or is
running. `GET /api/projects/:id/boot_log` pages through one step's log. The
project page follows the sandbox's `{ type, id, status }` broadcasts (see
[Live updates](#live-updates)) and polls every 2 seconds while the sandbox
boots. A project's own changes are announced on `project_<id>`.

### The agent under evaluation

A project owns one dashboard agent, and its evaluation belongs to that agent.
The agent's `mcp_servers` name the project's current sandbox, and follow it to
each new one. Servers added in the agent editor are kept, and choosing the
target the agent already has keeps its edited name, description and
instructions.

- A repository without the engine gets the **App assistant**, whose tools are
  everything the sandbox's MCP facade serves.
- A repository that bundles the engine evaluates one of its own agents. Once
  the sandbox serves, `GET /api/projects/:id/synced_agents` lists the
  checkout's agents (its facade's `run_<slug>` tools), and
  `PATCH /api/projects/:id/target` with `synced_agent: "<slug>"` makes the
  project's agent answer through that one tool.

`POST /api/projects/:id/run_evaluation` runs the project's evaluation against
its sandbox. A sandbox that has expired is booted again first, and the run
stays pending until it serves. A boot that fails, or that is still booting
after an hour, fails the run with the reason.

## Authentication

**The dashboard has no authentication by default.** Anyone who can reach
the route can read your traces. Before deploying anywhere non-local, set
an authentication method in the initializer:

```ruby
ActionAgent.configure do |config|
  # Any proc that authenticates the request — Devise, Rails 8 sessions, basic auth…
  config.authentication_method = ->(controller) do
    controller.authenticate_admin!
  end
end
```

A browser that asks for a dashboard page without a valid session is sent
to `config.sign_in_path` when one is set — your app's sign-in page — and
otherwise shown a minimal session-expired page. API and MCP clients get a
bare 401 either way. `config.sign_out_path` is the endpoint the header's
"Sign out" item POSTs to (with `_method=delete` and the CSRF token); the
engine has no session of its own, so leave it unset to hide the item.

```ruby
ActionAgent.configure do |config|
  config.authentication_method = ->(controller) { controller.authenticate_admin! }
  config.sign_in_path = "/admin/sign_in"
  config.sign_out_path = "/admin/sign_out"
end
```

Or constrain the mount in `config/routes.rb`:

```ruby
authenticate :user, ->(u) { u.admin? } do
  mount ActionAgent::Engine => "/activeagents"
end
```

The engine's controllers are their own base class, so your app's session
helpers are not on them. `config.controller_concerns` puts a concern of
yours there for the lambda to call — see
[Extending engine models and controllers](/framework/self-hosted-observability#extending-engine-models-and-controllers).

The local ingest endpoint accepts unauthenticated posts by default (it
receives traces from your own app process on your own machine). If the
mount is reachable from other machines, set `config.ingest_api_key` to
require a Bearer token — see
[Self-Hosted Observability](/framework/self-hosted-observability). In
multi-tenant mode ingest always authenticates per-account keys (see
below).

### Permissions

Authentication decides who reaches the dashboard. `config.permission_checker`
decides which of them may perform its privileged actions. It is called with
the signed-in user (the dashboard's `current_user`), the action, and the
record the action applies to. For an action that creates a record, that is
the unsaved record, with its owner columns already set. A truthy answer
allows the action, and `false` denies it with HTTP 403:

```ruby
ActionAgent.configure do |config|
  config.permission_checker = ->(user, action, subject) do
    user.present? && user.admin?
  end
end
```

| Action | Asked by |
|---|---|
| `:manage_credentials` | storing, testing and deleting an organization provider credential (`POST /api/provider_keys`, `POST /api/provider_keys/test`, `DELETE /api/provider_keys/:provider`), and storing or testing a member's personal Ollama host; a member's other personal keys need no permission |
| `:manage_github` | connecting GitHub, choosing its repositories, and disconnecting it (`GET /api/github_connection/connect` and `/callback`, `PATCH` and `DELETE /api/github_connection`); installing and linking the GitHub App, listing and choosing an installation's repositories, and unlinking it (`GET /api/github_installations/install` and `/callback`, `GET /api/github_installations/:id/repositories`, `PATCH` and `DELETE /api/github_installations/:id`); creating the App from a manifest (`POST /api/github_app_manifest`, `GET /api/github_app_manifest/callback`) |
| `:manage_api_keys` | creating and revoking dashboard API keys (`POST /api/api_keys`, `DELETE /api/api_keys/:id`) |
| `:publish_pull_request` | reserved: opening a pull request from a sandbox |
| `:answer_input_request` | answering or declining a paused run's request for input (`POST /api/input_requests/:id/answer` and `/decline`, and the MCP `input_requests_answer` tool) |
| `:manage_project_secrets` | setting, replacing and removing a project's secrets (`POST /api/projects` with `secrets`, `PUT /api/projects/:id/secrets`, `PUT` and `DELETE /api/projects/:id/secrets/:name`), changing the ref they are handed to (`PATCH /api/projects/:id` with `default_ref`) and deleting a project that has them (`DELETE /api/projects/:id`). Always asked about a `ProjectSecret` |
| `:take_over_browser` | reserved: driving a run's browser by hand |
| `:manage_recordings` | deleting a session recording (`DELETE /api/session_recordings/:id`) |
| `:replace_scenarios` | creating an evaluation or merging scenarios into one over the MCP facade (`evaluations_create`, `scenarios_merge`), asked as the API key's user |

The list is `ActionAgent::PERMISSION_ACTIONS`. `ActionAgent.permitted?(user,
action, subject)` asks the checker the same way the endpoints do, and raises
`ArgumentError` for an action outside the list. Reading a setting is not a
privileged action, so the `GET` endpoints that list keys or the connection
are not checked. Listing an installation's repositories is: the installation
can reach repositories a member cannot see on GitHub. The connect, install and callback navigations return a
refusal to Settings (`?github=forbidden` or `?github_app=forbidden`) rather
than as JSON.

Unset, anyone who passes authentication may perform every action, which
suits a single-user install. In multi-tenant mode that is every member of
every tenant, so the engine logs a warning at boot when `multi_tenant` is on
and no checker is set. The one exception is a run's request for input that
records the run's actor: in multi-tenant mode only that actor may answer it. With a checker set:

- An exception raised by the checker denies the action, and is logged.
- In multi-tenant mode, a request with no signed-in user is denied without
  asking the checker, and a `nil` answer denies.
- In single-tenant mode, a `nil` answer allows, so a checker can leave the
  actions it has no rule for alone.

### Organization and personal provider keys

A provider key belongs to the owner keys are stored under: with an
`account_class`, the account, which shares it with every member. That is an
organization key, and it is what runs use by default.

With `config.provider_key_scope = :personal_override`, a member may also
save a personal key per provider in Settings → API Keys. A personal key sends
the organization's agent traffic to that member's own provider account, so an
install opts in, and the setting has no effect without an `account_class`.

Every generation resolves its credentials through
`ActionAgent::ProviderCredentials.resolve(owner:, actor:, provider:)`, which
tries these sources in order:

1. the actor's personal key, under `:personal_override` when there is an
   actor;
2. `config.provider_credentials_resolver`;
3. the organization key;
4. nothing, so `config/active_agent.yml` and ENV apply.

| Generation | Actor |
|---|---|
| Agent runs | the user who started the run; over MCP, the user who created the API key |
| The agent builder's model pickers, the dashboard assistant | the signed-in user |
| Scenario replays, and the evaluation form's provider list | the caller a replay runs as (`ScenarioEvaluationRunner.replay_actor_for`): none on a multi-tenant install, so the organization key |
| The evaluation judge | none, so the organization key |
| Sandbox environments, Claude Code and Codex status | none: personal keys never reach a sandbox, and Claude Code and Codex keys are organization keys only |

A resolver that declares an `actor:` keyword, or accepts `**`, is told the
actor; a two-argument resolver is called as `(owner, provider)`:

```ruby
config.provider_credentials_resolver = ->(owner, provider, actor: nil) do
  owner.provider_credentials_for(provider)
end
```

With `multi_tenant` on, resolution fails closed: when the owner does not
resolve to the configured owner class, or the resolver raises, the run, judge
call or assistant request fails with `ActionAgent::ProviderCredentials::Unresolved`
instead of continuing on `config/active_agent.yml` or ENV credentials. On a
single-tenant install a raising resolver is logged and the next source is
tried.

`ActionAgent::ProviderKey.for_owner` and the dashboard API read organization
keys only. `ActionAgent::ProviderKey.personal_for(owner, actor)` is the one way
to reach a member's personal keys.

The provider keys endpoints take `scope=organization` (the default) or
`scope=personal`. Organization writes ask `permission_checker` for
`:manage_credentials`; personal writes change only the signed-in user's own
key, and are refused with 422 when personal keys are off. Claude Code and
Codex keys cannot be personal. `GET /api/provider_keys` rows carry `scope`,
`editable`, `effective_source` (`personal`, `host_resolver`, `organization`,
`config` or `none`, for the caller's own runs), `set_by` and `updated_at`.
`POST /api/provider_keys/test` sends a stored key only to the stored host.

A personal Ollama host decides where the server sends requests: the
connection test, the model list and every run the member starts reach it. So
storing or testing one asks `permission_checker` for `:manage_credentials`,
with the personal key as the subject, and a checker that wants members to
choose their own hosts allows it when `subject.personal?`. Removing one's own
key never asks.

The Organization page lists the members `config.members_resolver` returns,
and links "+ Invite Member" to `config.member_invite_url`:

```ruby
config.members_resolver = ->(account) do
  account.members.map { |user| { id: user.id, name: user.name, email: user.email, role: user.role } }
end
config.member_invite_url = "/team/invitations/new"
```

`GET /api/members` renders only `id`, `name`, `email` and `role`. With no
resolver, or one that raises, it lists the signed-in user alone, and with no
invite URL the button is hidden.

## Sending traces to a remote endpoint instead

Point telemetry at any compatible receiver — including the hosted
platform — instead of (or in addition to) local storage:

```yaml
telemetry:
  enabled: true
  endpoint: https://api.activeagents.ai/v1/traces
  api_key: <%= ENV["ACTIVEAGENTS_API_KEY"] %>
```

The wire format is documented in [telemetry.md](./telemetry.md) under
"self-hosting endpoint requirements" — anything that speaks it can feed
or receive these traces.

## Multi-tenant mode (running your own platform)

The engine also supports account-scoped deployments — this is exactly how
the hosted platform runs it:

```ruby
ActionAgent.configure do |config|
  config.multi_tenant = true
  config.account_class = "Account"        # must have a telemetry_api_key column
  config.trace_model_class = "TelemetryTrace" # optional model override
end
```

Every owned model reads and writes its owner by class. If you also set
`config.user_class`, agents, sandboxes, recordings and code sessions are owned
per user while keys and connections are owned per account; a platform that
scopes everything by account re-declares `owned_by :account, :user` on the
user-first models from `to_prepare` and sets `config.tenant_resolver` so a
user maps to its account. The install generator's template shows both. An
owner of another class than a model is owned by reads nothing.

In multi-tenant mode the ingest API authenticates with
`Authorization: Bearer <account.telemetry_api_key>` and processes traces
asynchronously through `ActionAgent::ProcessTelemetryTracesJob`
(idempotent per trace_id, capped at 100 traces per request). Add an
`increment_telemetry_usage!` method to your account model to hook usage
tracking or rate limiting; it is called once per authenticated trace ingest
request. The evaluation report collector authenticates the same keys but does
not call it: it asks `quota_checker` with `:evaluation_report` and tells
`usage_recorder` of each stored report.

### Live updates

When the host has loaded Action Cable, the engine announces status changes
on these streams:

| Stream | `type` | `id` |
|---|---|---|
| `agent_run_<run id>`, `agent_runs_<agent id>` | `update` | the run's id |
| `sandbox_<session id>` | `status_update` | the sandbox's session id |
| `sandbox_<session id>` | `run_started`, `run_complete`, `run_error` | the `run_id` that `POST /api/sandboxes/:id/run` or `POST /api/sandboxes/compare` returned, which is not the `id` of the run stored on the sandbox |

Each message is `{ type, id, status }` and nothing else: a client reads the
record back over the dashboard's JSON API, which scopes it to the signed-in
owner. The engine ships no channel classes; a host channel that streams these
checks that the subscriber owns the record before it streams. Without Action
Cable nothing is sent, and the dashboard polls.

## Relationship to the hosted platform

| | This engine | activeagents.ai (production) |
|---|---|---|
| Intended use | Development, or your own production mount | Managed production |
| Traces + span waterfall | ✓ | ✓ |
| Metrics + per-agent stats | ✓ | ✓ |
| Trace ingest API | ✓ (single tenant, local) | ✓ (multi-tenant, quotas) |
| Agent builder, runs, versions | ✓ | ✓ |
| Conversations, evaluations, scorecards, cost estimates | ✓ built in | ✓ |
| Accounts, plans, billing, managed sandboxes | Yours to operate | ✓ |

One gem, two contexts: it shows your traces while you develop, and the
platform runs the same engine multi-tenant with managed infrastructure. What
the platform adds is the business around it — accounts, plans, billing,
quotas and cloud sandboxes — not a bigger feature set. To run it as a
shared production surface of your own, see
[Self-Hosted Dashboard](/framework/self-hosted-observability).

## Conversation persistence

`actionagent` depends on
[solid_agent](https://github.com/activeagents/solid_agent), so it is already
in your bundle — the Interactions view is built on the contexts, messages and
generations `SolidAgent::HasContext` records, and dashboard runs persist
through it. The concern resolves those by name to solid_agent's own
`AgentContext`, `AgentMessage` and `AgentGeneration` models, so run its
installer once as well:

```bash
rails generate solid_agent:install
rails db:migrate
```

Include the same concern in your own agents to persist their conversations
alongside traces; generation records carry the same `trace_id` for
correlation:

```ruby
class ApplicationAgent < ActiveAgent::Base
  include SolidAgent::HasContext
  has_context contextual: :user
end
```

See [Persistence (SolidAgent)](/solid_agent) for the rest of what that gem
records — the tool exchange, long-term memory, runs and cost.
