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

- copies two migrations — `active_agent_telemetry_traces` (the trace store)
  and `active_agent_dashboard_tables` (agents, runs, versions,
  conversations, evaluations, sandboxes, recordings, keys); pass
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
| Agents | `/activeagents` | Your agents with per-agent request, token and error stats; build, edit, version and run them |
| Traces | `/activeagents/traces` | Every generation: agent + action, status, duration, tokens; expandable span timeline; All/Errors filter; 30s auto-refresh |
| Metrics | `/activeagents/metrics` | Last-24h totals: traces, tokens, avg duration, error rate, active agents; per-agent statistics |
| Interactions | `/activeagents/interactions` | The conversations behind the traces: messages, tool calls, generations |
| Evaluations | `/activeagents/evaluations` | Scored agent outputs |
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

**Modify the context.** The conversation on the page is the persisted
solid_agent context, and it is editable: hover a turn to **edit** or
**delete** it, use **Add message** to seed a user or assistant turn without
running anything, and **New conversation** to start from an empty context.
The system row shows the composed instructions the run executes under (edit
those on the Instructions tab). Editing a previous question and asking a
follow-up is the quickest way to see how an agent handles a changed history.

<video src="/dashboard/runner-context.webm" controls muted playsinline width="100%"></video>

**Attach files.** Files attached to a message upload with the run through
Active Storage (`AgentRun has_many_attached :attachments`), and reach the
model according to their kind: images as vision input, PDFs as documents,
and text-like files — CSV, Markdown, JSON, plain text — inlined into the
message, with the filename and size in a header the model can cite. The
persisted user message keeps an attachment manifest, so the conversation
shows the thumbnails afterwards. A host app without Active Storage keeps
everything else and answers attachment uploads with a clear 422.

![Attachments: an image and a CSV attached to one user message](/dashboard/runner-attachments.png)

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
ask for input and continue.

![Generative UI: stats, a chart and a table rendered from a render_ui tool call](/dashboard/runner-generative-ui.png)

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

Time-series charts on the console's metrics page use the optional
[groupdate](https://github.com/ankane/groupdate) gem when present and
degrade gracefully without it; the React metrics page does its own hourly
bucketing and needs nothing extra.

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

Or constrain the mount in `config/routes.rb`:

```ruby
authenticate :user, ->(u) { u.admin? } do
  mount ActionAgent::Engine => "/activeagents"
end
```

The local ingest endpoint accepts unauthenticated posts by default (it
receives traces from your own app process on your own machine). If the
mount is reachable from other machines, set `config.ingest_api_key` to
require a Bearer token — see
[Self-Hosted Observability](/framework/self-hosted-observability). In
multi-tenant mode ingest always authenticates per-account keys (see
below).

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

In multi-tenant mode the ingest API authenticates with
`Authorization: Bearer <account.telemetry_api_key>` and processes traces
asynchronously through `ActionAgent::ProcessTelemetryTracesJob`
(idempotent per trace_id, capped at 100 traces per request). Add an
`increment_telemetry_usage!` method to your account model to hook usage
tracking or rate limiting.

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
