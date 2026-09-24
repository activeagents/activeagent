# Self-Hosted Dashboard

Run the Active Agent dashboard inside your own Rails app: build and run
agents, read their conversations, score them, and watch traces, span
waterfalls and metrics — all served from your database, on your domain.
Data never leaves your infrastructure.

This is the same engine that powers the [dev console](/framework/dashboard)
and the hosted platform at activeagents.ai. This guide covers deploying it
as a shared, production surface for a team or a fleet of apps. If you just
want traces while you build on your laptop, the dev console quick start is
all you need.

## Two ways to run it

| | Self-hosted engine | Hosted platform (activeagents.ai) |
|---|---|---|
| Where data lives | Your database | Your workspace on the platform |
| Setup | Add `actionagent` and mount its engine in a Rails app | Point telemetry at an API key |
| Traces + span waterfall | ✓ | ✓ |
| Metrics (24h aggregates, per-agent stats) | ✓ | ✓ |
| Ingest API for remote apps | ✓ (`<mount>/api/traces`) | ✓ (`https://api.activeagents.ai/v1/traces`) |
| Evaluation reports published by remote apps | ✓ (`<mount>/api/evaluation_reports`) | ✓ (`https://api.activeagents.ai/v1/evaluations`) |
| Agent builder, runs, versions | ✓ | ✓ |
| Interactions (tool-call conversations), evaluations, scorecards, cost estimates | ✓ | ✓ |
| Agents as an MCP server | ✓ (`<mount>/mcp`) | ✓ |
| Accounts, plans, billing, managed sandbox infrastructure | Yours to operate | ✓ |

The platform is this engine in multi-tenant mode plus the things a hosted
product has to have — accounts, plans, billing and cloud sandboxes. The
feature surface is the same one, not a smaller version of it.

The wire format is identical too, so the choice is per-environment, not
per-app: the same `config/active_agent.yml` switches between them (see
[Getting traces in](#getting-traces-in)), and the same publisher call
delivers an evaluation report to either (see
[Getting evaluation reports in](#getting-evaluation-reports-in)).

## Install

The dashboard is its own gem. `activeagent` is the framework — agents,
providers, generation — and `actionagent` is the mountable dashboard, which
brings Active Record and [solid_agent](https://github.com/activeagents/solid_agent)
with it. An app that only wants to run agents installs the first and pays for
neither:

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

The generator creates:

- `db/migrate/*_create_active_agent_telemetry_traces.rb` — the trace store,
- `db/migrate/*_create_active_agent_dashboard_tables.rb` — everything else
  the dashboard reads and writes (agents, runs, versions, conversations,
  evaluations, sandboxes, recordings, keys),
- `db/migrate/*_create_active_agent_evaluation_scenarios.rb` — scenario
  suites and their per-scenario, per-model results (re-run the generator on
  an existing install to get it),
- `db/migrate/*_add_evaluation_report_identity.rb` — the identity of a run
  an application published rather than the dashboard executed (a no-op on a
  fresh install, whose evaluation runs table already has it; re-run the
  generator on an existing install to get it),
- `mount ActionAgent::Engine => "/activeagents"` in
  `config/routes.rb`,
- `config/initializers/action_agent.rb` — authentication,
  ingest key and multi-tenant options, commented.

Open `http://localhost:3000/activeagents` and you have the dashboard.

Pass `--traces_only` for an app that should just be a trace sink, and
`--skip_migrations` / `--skip_routes` if you manage either yourself.

API keys and provider credentials are encrypted at rest, so run
`rails db:encryption:init` and add the keys to your credentials before
creating any. (`ActionAgent.encrypt_credentials = false` stores
them in plain text instead — a deliberate downgrade, not a default.)

### What you get

The dashboard is a React app served by the engine, with its bundle shipped
prebuilt in the `actionagent` gem — mounting it does not ask your app to run a
JavaScript build or adopt a frontend framework. Its client-side routes live under the
mount, so `/activeagents/traces`, `/activeagents/evaluations` and the rest
are all real, linkable URLs.

A server-rendered console lives at `<mount>/console/traces` for the same
trace and metric data without JavaScript.

## Routing: a path or a subdomain

The mount path is yours to choose. The ingest route always lives at
`<mount>/api/traces`, and under `local_storage: true`
`ActiveAgent::Telemetry::Configuration#resolved_endpoint` reports it for
whatever mount the app actually uses — handy for diagnostics. (Same-app
capture writes through the trace model and issues no HTTP at all, so that
path is a label, not a request; apps posting from elsewhere set `endpoint:`
to the full URL, as shown below, and `resolved_endpoint` returns that.)

```ruby
# A path on your main app:
mount ActionAgent::Engine => "/activeagents"

# Or the root of a dedicated subdomain, e.g. activeagents.example.com:
constraints subdomain: "activeagents" do
  mount ActionAgent::Engine => "/", as: :active_agent_subdomain
end
```

With the subdomain mount, the dashboard lives at
`https://activeagents.example.com/` and remote apps post traces to
`https://activeagents.example.com/api/traces`.

## Authentication (required in production)

Traces contain prompts, outputs and error messages. Without an
`authentication_method` the dashboard refuses to serve in production
(HTTP 403), so set one before deploying:

```ruby
# config/initializers/action_agent.rb
ActionAgent.configure do |config|
  # Basic auth:
  config.authentication_method = ->(controller) {
    controller.authenticate_or_request_with_http_basic do |username, password|
      username == "ops" && password == Rails.application.credentials.dashboard_password
    end
  }
  # ...or Devise: ->(controller) { controller.authenticate_admin! }
end
```

The ingest API — trace ingest and the evaluation report collector —
authenticates separately. In single-tenant mode it accepts
unauthenticated posts by default (fine for same-app `local_storage`, not
for a network-reachable mount) — set an ingest key whenever other
machines can reach it:

```ruby
config.ingest_api_key = Rails.application.credentials.dig(:active_agent, :ingest_api_key)
```

Requests without a matching `Authorization: Bearer <key>` header get a
401. The telemetry reporter, `ruby_llm_telemetry` and
`ActiveAgent::Evals::Publisher` already send their configured `api_key` as
a Bearer header, so remote apps need no changes.

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
    endpoint: https://activeagents.example.com/api/traces
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
accounts, enable `config.multi_tenant` with `account_class` and a
`current_account_resolver` lambda (the engine's controllers are their own
base class, so your app's `current_account` helper is not on them); ingest
then authenticates per-account `telemetry_api_key` Bearer tokens and
processes asynchronously via
`ActionAgent::ProcessTelemetryTracesJob` (requires an Active Job backend),
the evaluation report collector authenticates the same tokens, and every
dashboard query scopes to the current account. Most self-hosted installs
should leave this off.

## Getting evaluation reports in

An application that runs its agents itself can evaluate them in-process with
`ActiveAgent::Evals` and publish the finished report to your mount with
`ActiveAgent::Evals::Publisher`. The engine stores it as its own evaluation
rows — an observed agent for the report's `source` and `agent_name`, an
evaluation named for its suite and scope, and a complete run — so the
Evaluations page shows it the way it shows a run the dashboard executed. The
dashboard never executes that application's agent.

```ruby
ActiveAgent::Evals::Publisher.new(
  endpoint: "https://activeagents.example.com/api/evaluation_reports",
  api_key: Rails.application.credentials.dig(:active_agent, :ingest_api_key)
).call(report: report, run_id: report.metadata.fetch("run_id"),
       source: "support-app", agent_name: "SupportBot", suite: "orders")
```

The endpoint is `<mount>/api/evaluation_reports`, authenticated with the same
key as trace ingest (the tenant's key in multi-tenant mode). A `run_id` is
stored once per install, or once per tenant: an identical retry returns the
stored run with HTTP 200, and different content under that `run_id` is a 409.
A host that meters its install answers the `:evaluation_report` kind from
`quota_checker` (a denial is a 429), and `usage_recorder` is told of each
stored report. The envelope, the validation rules and every response are in
[Publishing an externally executed evaluation](/evals/publication).

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
  endpoint: "https://activeagents.example.com/api/traces",
  api_key: Rails.application.credentials.dig(:active_agent, :ingest_api_key),
  service_name: "billing-app"
)
```

Attribute traffic to named agents with `with_agent("SupportAgent", action: "respond") { ... }`
or an `agent_resolver:` lambda — otherwise traffic reports as
`RubyLLM::Chat`. See the bridge's README for content capture
(off by default) and turn semantics.

An app that mounts this dashboard itself can write traces through the trace
model instead of posting to its own ingest route. The full walkthrough —
same-app and remote topologies, authentication, naming traffic, content
capture — is [Dashboard for RubyLLM Apps](/framework/ruby_llm_dashboard).

## Conversation persistence with solid_agent

Telemetry gives you traces; [solid_agent](https://github.com/activeagents/solid_agent)
additionally persists conversations (contexts, messages, generations —
including tool calls with arguments and results) in your database.

`actionagent` depends on it, so the gem is already in your bundle: the
dashboard's execution service mixes `SolidAgent::HasContext` into every run,
and the Interactions view reads what that concern records. It resolves the
context, message and generation models by name, so the dashboard's own runs
need the ones solid_agent's installer generates — run it too, not only for the
agents you write by hand:

```bash
rails generate solid_agent:install
rails db:migrate
```

Generations record the same `trace_id` the telemetry pipeline uses
(thread it via `prompt_options[:trace_id]`), so conversation rows and
dashboard traces correlate.

## Extending engine models and controllers

A host usually has concerns its own models and controllers already carry —
a connection-switching concern that pins tables to one database, a request
instrumentation or audit concern on every controller. Two settings apply
them to the engine's classes. The engine includes them as those classes
load, so they are in place before any subclass is defined, and again after
every code reload:

```ruby
# config/initializers/action_agent.rb
ActionAgent.configure do |config|
  # Included into ActionAgent::ApplicationRecord, and so into every engine
  # model.
  config.model_concerns = ["MyApp::ConnectionSwitching"]

  # Included into ActionAgent::ApplicationController, and so into every
  # dashboard controller — the React dashboard and its JSON API, the
  # server-rendered console and the MCP facade — ahead of the engine's own
  # callbacks, so a before_action or around_action runs before the
  # dashboard authenticates.
  config.controller_concerns = ["MyApp::RequestTagging"]
end
```

Entries are modules or their names. A name is resolved when the class
loads, so the initializer can refer to a constant your app has not
autoloaded yet, and a name that resolves to nothing raises `NameError`
there rather than being skipped. Set them in an initializer: the classes
load after the initializers have run, and a concern added later is not
applied.

The ingest endpoints, `ActionAgent::Api::TracesController` and
`ActionAgent::Api::EvaluationReportsController`, are not dashboard
controllers — they authenticate with a bearer token and inherit
`ActionController::API` — so controller concerns do not reach them.

`authentication_method` still decides who is admitted. A controller
concern puts your app's session helpers on the engine's controllers, and
the lambda is where you call them. The engine's own `current_user` keeps
precedence over one a concern defines, so a concern's `current_user` is not
reachable on the engine's controllers: `current_user_resolver` remains what
names the signed-in user to the engine, and it and `authentication_method`
call the concern through a method the engine does not define, such as
`->(controller) { controller.send(:user_from_session) }`.

## Operations

- **Retention is yours.** Nothing prunes automatically. Set a window and
  schedule the job that ships with the engine:

  ```ruby
  ActionAgent.trace_retention = 30.days
  # config/recurring.yml
  # trace_retention:
  #   class: ActionAgent::TraceRetentionJob
  #   schedule: every day at 4am
  ```

  Pass a callable instead of a duration for per-tenant windows.
- **Database portability.** SQLite, MySQL and PostgreSQL all work. Queries
  with a much faster PostgreSQL form (jsonb traversal and containment,
  `date_trunc`) use it when the adapter has it and fall back to portable SQL
  when it doesn't. JSON columns are declared `jsonb` on PostgreSQL and
  `json` elsewhere.
- **CDN assets.** The React dashboard's CSS and JS are served from the
  `actionagent` gem, which adds its own `app/assets/builds` to your asset
  paths, so it works on CSP-strict and air-gapped networks. The server-rendered
  console at `<mount>/console/traces` still loads Tailwind, Turbo and
  Stimulus from public CDNs and renders unstyled without them — set
  `config.layout` to a layout of your own that bundles them locally.
- **Time-series charts** on the console's metrics page light up when the
  optional [groupdate](https://github.com/ankane/groupdate) gem is
  installed. The React metrics page buckets by hour with the same portable
  SQL and needs nothing extra.
- **Sensitive content.** Prompt/output capture obeys the telemetry
  `redact_attributes` configuration — see [Telemetry](/framework/telemetry).

## Troubleshooting

- **No traces appear** — telemetry is opt-in per environment: check
  `enabled: true` (and `local_storage: true` for same-app storage) under
  the *current* environment key in `config/active_agent.yml`.
- **403 in production** — set `config.authentication_method` (see above).
- **401 from ingest or the evaluation report collector** — the poster's
  `api_key` doesn't match `config.ingest_api_key` (single-tenant) or an
  account `telemetry_api_key` (multi-tenant).
- **Console metrics page has no chart** — install `groupdate`.

## Running agents from the dashboard

Agents you build in the dashboard execute through `activeagent` against
whichever provider `config/active_agent.yml` has credentials for, or the credentials
stored per owner under Settings -> Provider API Keys. There is no mock
fallback: a run with no usable credentials fails and says so, so nothing
stored ever reflects a fabricated response.

Set `ActionAgent.execution_enabled = false` to run the mount as
a read-only observability surface instead.

Sandboxes are the one part that needs infrastructure the engine can't ship.
It includes an in-memory backend and a registry; register your own to run
agents in real containers:

```ruby
ActionAgent.sandbox_backends = { "cloud_run" => "CloudRunService" }
ActionAgent.sandbox_service = "cloud_run"
```
