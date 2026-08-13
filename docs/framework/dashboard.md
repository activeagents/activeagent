# Dev Console (Dashboard Engine)

Active Agent ships its dashboard as a Rails engine: every agent generation
recorded as a trace with a span waterfall, a metrics overview, and the
agent builder, interactions and evaluations alongside them — running
inside your app against your own database while you build. The hosted
[activeagents.ai](https://activeagents.ai) platform mounts this engine too,
so what you see locally in development is what the platform shows (plus the
accounts, plans, billing and managed sandbox infrastructure a hosted
product has to have) once you point telemetry at it. Every platform
workspace starts with a free low-volume trial.

![Dashboard: traces list with expandable span timelines]

## Quick start

```bash
rails generate active_agent:dashboard:install
rails db:migrate
```

The generator:

- copies two migrations — `active_agent_telemetry_traces` (the trace store)
  and `active_agent_dashboard_tables` (agents, runs, versions,
  conversations, evaluations, sandboxes, recordings, keys); pass
  `--traces_only` for a trace sink alone,
- mounts the engine at `/activeagents`,
- writes `config/initializers/active_agent_dashboard.rb`.

API keys and provider credentials are encrypted at rest, so run
`rails db:encryption:init` before creating any (or set
`ActiveAgent::Dashboard.encrypt_credentials = false` to store them in plain
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
bundle ships prebuilt in the gem, so mounting it doesn't ask your app to
run a JavaScript build.

## What you get

| Page | Path | Contents |
|------|------|----------|
| Agents | `/activeagents` | Your agents with per-agent request, token and error stats; build, edit, version and run them |
| Traces | `/activeagents/traces` | Every generation: agent + action, status, duration, tokens; expandable span timeline; All/Errors filter; 30s auto-refresh |
| Metrics | `/activeagents/metrics` | Last-24h totals: traces, tokens, avg duration, error rate, active agents; per-agent statistics |
| Interactions | `/activeagents/interactions` | The conversations behind the traces: messages, tool calls, generations |
| Evaluations | `/activeagents/evaluations` | Scored agent outputs |
| Console | `/activeagents/console/traces` | The same traces and metrics server-rendered, without JavaScript; span waterfall per trace at `/activeagents/console/traces/:id` |
| Ingest API | `POST /activeagents/api/traces` | JSON trace ingestion (used by `local_storage` mode and remote SDKs) |

Time-series charts on the console's metrics page use the optional
[groupdate](https://github.com/ankane/groupdate) gem when present and
degrade gracefully without it; the React metrics page buckets in Ruby and
needs nothing extra.

## Authentication

**The dashboard has no authentication by default.** Anyone who can reach
the route can read your traces. Before deploying anywhere non-local, set
an authentication method in the initializer:

```ruby
ActiveAgent::Dashboard.configure do |config|
  # Any proc that authenticates the request — Devise, Rails 8 sessions, basic auth…
  config.authentication_method = ->(controller) do
    controller.authenticate_admin!
  end
end
```

Or constrain the mount in `config/routes.rb`:

```ruby
authenticate :user, ->(u) { u.admin? } do
  mount ActiveAgent::Dashboard::Engine => "/activeagents"
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
ActiveAgent::Dashboard.configure do |config|
  config.multi_tenant = true
  config.account_class = "Account"        # must have a telemetry_api_key column
  config.trace_model_class = "TelemetryTrace" # optional model override
end
```

In multi-tenant mode the ingest API authenticates with
`Authorization: Bearer <account.telemetry_api_key>` and processes traces
asynchronously through `ActiveAgent::ProcessTelemetryTracesJob`
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

One engine, two contexts: it shows your traces while you develop, and the
platform runs the same code multi-tenant with managed infrastructure. What
the platform adds is the business around it — accounts, plans, billing,
quotas and cloud sandboxes — not a bigger feature set. To run it as a
shared production surface of your own, see
[Self-Hosted Dashboard](/framework/self-hosted-observability).

## Conversation persistence

Pair the dashboard with the `solid_agent` gem to persist full
conversations (contexts, messages, generations) alongside traces; its
generation records carry the same `trace_id` for correlation:

```ruby
class ApplicationAgent < ActiveAgent::Base
  include SolidAgent::HasContext
  has_context contextual: :user
end
```
