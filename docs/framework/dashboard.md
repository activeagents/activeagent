# Dev Console (Dashboard Engine)

Active Agent ships a local development console as a Rails engine: every
agent generation recorded as a trace with a span waterfall, plus a metrics
overview — running inside your app against your own database while you
build. It uses the same telemetry pipeline as the hosted
[activeagents.ai](https://activeagents.ai) platform, which is the
production observability product: what you see locally in development is
what the platform shows (plus evaluations, cost estimates, retention, and
team workspaces) once you point telemetry at it. Every platform workspace
starts with a free low-volume trial.

![Dashboard: traces list with expandable span timelines]

## Quick start

```bash
rails generate active_agent:dashboard:install
rails db:migrate
```

The generator:

- copies the `active_agent_telemetry_traces` migration (plus agent,
  run, template, sandbox and recording tables for the full install),
- mounts the engine at `/active_agent`,
- writes `config/initializers/active_agent_dashboard.rb`.

Then enable telemetry with local storage in `config/active_agent.yml`:

```yaml
telemetry:
  enabled: true
  local_storage: true
```

That's it. Run any agent and open `/active_agent` — each generation
appears as a trace with prompt/LLM/tool spans, timing, token usage
(input / output / thinking), provider and model.

## What you get

| Page | Path | Contents |
|------|------|----------|
| Traces | `/active_agent/traces` | Every generation: agent + action, status, duration, tokens; expandable span timeline; All/Errors filter; 30s auto-refresh |
| Trace detail | `/active_agent/traces/:id` | Span waterfall with relative offsets, token breakdown, error details, raw payload |
| Metrics | `/active_agent/traces/metrics` | Last-24h totals: traces, tokens, avg duration, error rate, active agents; per-agent statistics |
| Ingest API | `POST /active_agent/api/traces` | JSON trace ingestion (used by `local_storage` mode and remote SDKs) |

Time-series charts on the metrics page use the optional
[groupdate](https://github.com/ankane/groupdate) gem when present and
degrade gracefully without it.

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
  mount ActiveAgent::Dashboard::Engine => "/active_agent"
end
```

The local ingest endpoint is unauthenticated in local mode by design (it
receives traces from your own app process). In multi-tenant mode it
requires a Bearer token (see below).

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

| | Dev console (this engine) | activeagents.ai (production) |
|---|---|---|
| Intended use | Development | Production monitoring |
| Traces + span waterfall | ✓ | ✓ |
| Metrics + per-agent stats | ✓ | ✓ |
| Trace ingest API | ✓ (single tenant, local) | ✓ (multi-tenant, quotas) |
| Conversation persistence | via [solid_agent](https://github.com/activeagents/solid_agent) | ✓ built in |
| Evaluations, cost estimates, retention, team accounts | — | ✓ |

One pipeline, two contexts: the console shows your traces while you
develop; the platform runs the same engine multi-tenant with managed
infrastructure for production. Free workspaces get a low-volume trial
tier; paid plans lift the quotas.

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
