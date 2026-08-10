# Self-Hosted Observability (Enterprise)

Run the Active Agent dashboard inside your own Rails app: traces, span
waterfalls and metrics served from your database, on your domain. Data
never leaves your infrastructure.

This is the same engine that powers the [dev console](/framework/dashboard)
— this guide covers deploying it as a shared, production observability
surface for a team or a fleet of apps. If you just want traces while you
build on your laptop, the dev console quick start is all you need.

## Two ways to run observability

| | Self-hosted engine | Hosted platform (activeagents.ai) |
|---|---|---|
| Where data lives | Your database | Your workspace on the platform |
| Setup | Mount the engine in a Rails app | Point telemetry at an API key |
| Traces + span waterfall | ✓ | ✓ |
| Metrics (24h aggregates, per-agent stats) | ✓ | ✓ |
| Ingest API for remote apps | ✓ (`<mount>/api/traces`) | ✓ (`https://api.activeagents.ai/v1/traces`) |
| Interactions (tool-call conversations), evaluations, scorecards, cost estimates | — | ✓ |
| Retention policies, team workspaces, plans | Yours to operate | ✓ |

The wire format is identical, so the choice is per-environment, not
per-app: the same `config/active_agent.yml` switches between them (see
[Getting traces in](#getting-traces-in)).

## Install

```ruby
# Gemfile
gem "activeagent"
```

```bash
bundle install
rails generate active_agent:dashboard:install
rails db:migrate
```

The generator creates exactly three things:

- `db/migrate/*_create_active_agent_telemetry_traces.rb` — the one table
  the dashboard reads,
- `mount ActiveAgent::Dashboard::Engine => "/activeagents"` in
  `config/routes.rb`,
- `config/initializers/active_agent_dashboard.rb` — authentication,
  ingest key and multi-tenant options, commented.

Open `http://localhost:3000/activeagents` and you have the dashboard.
(`--skip_migrations` / `--skip_routes` are available if you manage either
yourself.)

## Routing: a path or a subdomain

The mount path is yours to choose — the telemetry client derives its
local ingest endpoint from wherever the engine is actually mounted, so
nothing else needs configuring:

```ruby
# A path on your main app:
mount ActiveAgent::Dashboard::Engine => "/activeagents"

# Or the root of a dedicated subdomain, e.g. activeagents.combinaut.com:
constraints subdomain: "activeagents" do
  mount ActiveAgent::Dashboard::Engine => "/", as: :active_agent_subdomain
end
```

With the subdomain mount, the dashboard lives at
`https://activeagents.combinaut.com/` and remote apps post traces to
`https://activeagents.combinaut.com/api/traces`.

## Authentication (required in production)

Traces contain prompts, outputs and error messages. Without an
`authentication_method` the dashboard refuses to serve in production
(HTTP 403), so set one before deploying:

```ruby
# config/initializers/active_agent_dashboard.rb
ActiveAgent::Dashboard.configure do |config|
  # Basic auth:
  config.authentication_method = ->(controller) {
    controller.authenticate_or_request_with_http_basic do |username, password|
      username == "ops" && password == Rails.application.credentials.dashboard_password
    end
  }
  # ...or Devise: ->(controller) { controller.authenticate_admin! }
end
```

The ingest API authenticates separately. In single-tenant mode it accepts
unauthenticated posts by default (fine for same-app `local_storage`, not
for a network-reachable mount) — set an ingest key whenever other
machines can reach it:

```ruby
config.ingest_api_key = Rails.application.credentials.dig(:active_agent, :ingest_api_key)
```

Requests without a matching `Authorization: Bearer <key>` header get a
401. The telemetry reporter and `ruby_llm_telemetry` already send their
configured `api_key` as a Bearer header, so remote apps need no changes.

## Getting traces in

**Same app** — the app that mounts the dashboard stores its own traces
directly, no HTTP involved:

```yaml
# config/active_agent.yml
production:
  telemetry:
    enabled: true
    local_storage: true
```

**Other ActiveAgent apps in your fleet** — point their telemetry at your
mount:

```yaml
production:
  telemetry:
    enabled: true
    endpoint: https://activeagents.combinaut.com/api/traces
    api_key: <%= Rails.application.credentials.dig(:active_agent, :ingest_api_key) %>
```

**The hosted platform instead** — same file, different endpoint; this is
what "cloud mode" is:

```yaml
production:
  telemetry:
    enabled: true
    endpoint: https://api.activeagents.ai/v1/traces
    api_key: <%= ENV["ACTIVEAGENTS_API_KEY"] %>
```

**Multi-tenant mode** — if your self-hosted install itself serves multiple
accounts, enable `config.multi_tenant` with `account_class` /
`current_account_method`; ingest then authenticates per-account
`telemetry_api_key` Bearer tokens and processes asynchronously via
`ActiveAgent::ProcessTelemetryTracesJob` (requires an Active Job backend),
and every dashboard query scopes to the current account. Most self-hosted
installs should leave this off.

## RubyLLM applications

Apps that use [RubyLLM](https://rubyllm.com) directly (no
`ActiveAgent::Base`) can report chats and tool calls to the same endpoint
with the
[activeagents-telemetry-ruby_llm](https://rubygems.org/gems/activeagents-telemetry-ruby_llm)
adapter:

```ruby
# Gemfile
gem "activeagents-telemetry-ruby_llm"
```

```ruby
# config/initializers/ruby_llm_telemetry.rb
ActiveAgents::Telemetry::RubyLLM.subscribe!(
  endpoint: "https://activeagents.combinaut.com/api/traces",
  api_key: Rails.application.credentials.dig(:active_agent, :ingest_api_key),
  service_name: "billing-app"
)
```

Attribute traffic to named agents with `with_agent("SupportAgent", action: "respond") { ... }`
or an `agent_resolver:` lambda — otherwise traffic reports as
`RubyLLM::Chat`. See the bridge's README for content capture
(off by default) and turn semantics.

## Optional: conversation persistence with solid_agent

Telemetry gives you traces; [solid_agent](https://github.com/activeagents/solid_agent)
additionally persists conversations (contexts, messages, generations —
including tool calls with arguments and results) in your database:

```bash
rails generate solid_agent:install
rails db:migrate
```

Generations record the same `trace_id` the telemetry pipeline uses
(thread it via `prompt_options[:trace_id]`), so conversation rows and
dashboard traces correlate.

## Operations

- **Retention is yours.** Nothing prunes automatically. A recurring job
  as simple as
  `ActiveAgent::TelemetryTrace.where("created_at < ?", 30.days.ago).delete_all`
  is enough.
- **Database portability.** The engine's queries are plain ActiveRecord —
  SQLite, MySQL and PostgreSQL all work. (The hosted platform's richer
  views use PostgreSQL-specific SQL; the engine deliberately doesn't.)
- **CDN assets.** The default layout loads Tailwind, Turbo and Stimulus
  from public CDNs. On CSP-strict or air-gapped networks the pages render
  unstyled (fully functional, but plain) — set `config.layout` to a
  layout of your own that bundles those assets locally.
- **Time-series charts** on the metrics page light up when the optional
  [groupdate](https://github.com/ankane/groupdate) gem is installed.
- **Sensitive content.** Prompt/output capture obeys the telemetry
  `redact_attributes` configuration — see [Telemetry](/framework/telemetry).

## Troubleshooting

- **No traces appear** — telemetry is opt-in per environment: check
  `enabled: true` (and `local_storage: true` for same-app storage) under
  the *current* environment key in `config/active_agent.yml`.
- **403 in production** — set `config.authentication_method` (see above).
- **401 from ingest** — the poster's `api_key` doesn't match
  `config.ingest_api_key` (single-tenant) or an account
  `telemetry_api_key` (multi-tenant).
- **Metrics page has no chart** — install `groupdate`.

## Future work

Rendering agent conversations persisted by RubyLLM's `acts_as` schema or
solid_agent tables directly in the engine (DB-level detection of agent
implementations) is on the roadmap; today those render on the hosted
platform via telemetry.
