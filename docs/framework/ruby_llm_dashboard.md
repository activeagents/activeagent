---
title: Dashboard for RubyLLM Apps
description: Add the ActiveAgents telemetry dashboard to an existing RubyLLM application. Report every chat turn and tool call as a trace and read them at a mount in your own app or on the hosted platform, without adopting ActiveAgent::Base.
---
# {{ $frontmatter.title }}

This guide is for an application that already calls models through
[RubyLLM](https://rubyllm.com) — `RubyLLM.chat`, `acts_as_chat` records,
`RubyLLM::Agent` subclasses — and wants the dashboard without rewriting any
of that. Two gems do it: `activeagents-telemetry-ruby_llm` reports each
conversation turn as a trace, and `actionagent` is the dashboard that stores
and renders them. Your agents keep running on RubyLLM; nothing here asks you
to adopt `ActiveAgent::Base`.

If your app is built on `ActiveAgent::Base`, you need neither adapter nor
this page — the framework reports its own telemetry. Start at
[Dev Console](/framework/dashboard) instead.

## What you get

One trace per conversation turn:

```
root   SupportBot.respond              1,240ms   OK
└─ llm llm.generate    gpt-4o  2 rounds  1,180ms  42 tokens
   └─ tool tool.search_docs               310ms   OK
```

The `root` span is named `<agent>.<action>` (see [Name your traffic](#_4-name-your-traffic)),
the `llm` span covers the whole provider loop with `llm.rounds` and token
totals, and each tool call gets a `tool.<name>` span with real timings. A
turn that raises reports as an `ERROR` trace rather than disappearing. The
dashboard shows the traces list, the span waterfall for each trace, and the
metrics view (24-hour aggregates and per-agent statistics).

The adapter supports RubyLLM 1.x and 2.x (2.x token counts need adapter
0.3.1 or later). The two generations arrange
tool rounds differently — 1.x nests a tool round inside the enclosing event,
2.x drives a flat `step until complete?` loop — and the adapter accumulates
rounds until the one that ends the turn, so both produce the same trace.

## Pick a topology

| | Traces go to | Auth | Use when |
|---|---|---|---|
| **Same app** | The engine's trace model, in-process (no HTTP) | Dashboard login only | Development; a single app that wants its own dashboard |
| **Separate dashboard app** | `https://<dashboard host>/<mount>/api/traces` | Dashboard login + an ingest key | One dashboard for a fleet of apps |
| **Hosted platform** | `https://api.activeagents.ai/v1/traces` | A platform API key | No dashboard to operate |

Same gems, same wire format, so the choice is per environment: the example
in [step 3](#_3-report-rubyllm-traffic) runs the same-app dashboard in
development and reports to the hosted platform in production.

## 1. Install the dashboard

Skip this step for the hosted platform.

```ruby
# Gemfile
gem "actionagent"
```

`actionagent` brings `activeagent` and [solid_agent](/solid_agent) with it;
your code never calls either. The host needs Active Record and an asset
pipeline (propshaft or sprockets-rails) to serve the prebuilt dashboard
bundles.

```bash
bundle install
rails generate action_agent:install
rails db:migrate
rails db:encryption:init   # the dashboard stores API keys encrypted
```

The generator also offers `--traces_only`, which installs the trace store
alone and leaves out the tables behind the agent builder and evaluation
views. Those views execute `ActiveAgent::Base` agents, which a RubyLLM app
has none of, so the flag looks like the natural choice — but the dashboard's
index page currently reads the agents table on every load and returns 500
without it. Until that is fixed, run the full install: the extra tables sit
empty. A `--traces_only` install still serves the JSON API and the
server-rendered console at `<mount>/console/traces`, if that is all you
want.

The generator mounts the engine and writes its initializer:

```ruby
# config/routes.rb
mount ActionAgent::Engine => "/activeagents"
```

The mount path is yours. An app with an admin area typically moves it
there (`/admin/activeagents`); the dashboard's client-side routes resolve
relative to whatever you choose. Its ingest endpoint is always
`<mount>/api/traces`.

## 2. Authenticate the dashboard

Traces carry prompts, outputs and error messages, so without an
`authentication_method` the dashboard refuses to serve anywhere except the
development and test environments (HTTP 403) — a staging or review app is
as reachable as production and is treated the same. The lambda receives the
engine's controller. The engine's
controllers are their own base class — your app's `current_user` helper is
not on them — so read the session or your auth library directly:

```ruby
# config/initializers/action_agent.rb
ActionAgent.configure do |config|
  # Session-based auth: admit only an admin with a live session.
  config.authentication_method = lambda do |controller|
    user = User.find_by(id: controller.session[:user_id])
    user.present? && user.admin?
  end

  # ...or Devise:
  # config.authentication_method = ->(controller) { controller.authenticate_admin! }

  # Where a browser goes when it has no valid session.
  config.sign_in_path = "/sign_in"
end
```

Return truthy to admit. A falsy return or a raise denies access; the engine
renders the 401, or the redirect to `sign_in_path`, itself.

For a **separate dashboard app**, also set the key other apps must present:

```ruby
config.ingest_api_key = Rails.application.credentials.dig(:active_agent, :ingest_api_key)
```

Posts without a matching `Authorization: Bearer <key>` header get a 401.
The adapter sends its configured `api_key` as that header, so the reporting
apps need nothing beyond the key. Leave `ingest_api_key` unset only when the
mount is unreachable beyond your own machine. Ingest answers `202 Accepted`;
in single-tenant mode the trace is stored before that response returns
(multi-tenant mode stores it through Active Job).

## 3. Report RubyLLM traffic

```ruby
# Gemfile
gem "activeagents-telemetry-ruby_llm"
```

The adapter subscribes to RubyLLM's `chat.ruby_llm` and `tool_call.ruby_llm`
events, which RubyLLM emits through its `instrumenter`. Under Rails, RubyLLM's
railtie sets `RubyLLM.config.instrumenter ||= ActiveSupport::Notifications`
(1.16 and 2.x). Outside Rails, or on an older 1.x, set it yourself in the
initializer below.

### Same app

The dashboard's trace model is in the same process, so write to it directly.
`local_store` receives each trace as a string-keyed hash and the SDK
descriptor; the engine's `create_from_payload` is the same method its HTTP
ingest calls:

```ruby
# config/initializers/ruby_llm_telemetry.rb
ActiveAgents::Telemetry.configure do |config|
  config.service_name = "billing-app"
  config.environment  = Rails.env
  config.local_store  = lambda do |trace, sdk|
    model = ActionAgent.trace_model
    next if model.exists?(trace_id: trace["trace_id"])

    model.create_from_payload(trace, sdk)
  end
end

ActiveAgents::Telemetry::RubyLLM.subscribe!
```

A `local_store` satisfies the reporter on its own: no endpoint, no key, no
HTTP. Delivery still runs on the reporter's background thread — set
`config.async = false` in the test environment so a trace is written before
the example that caused it ends. Content capture stays off unless you enable
it ([step 5](#_5-content-capture)).

### Separate dashboard app, or the hosted platform

Point the adapter at the endpoint and authenticate with the key it expects:
the dashboard app's `ingest_api_key`, or a platform API key
(Settings → API Keys on activeagents.ai).

```ruby
# config/initializers/ruby_llm_telemetry.rb
if ENV["ACTIVEAGENTS_API_KEY"].present?
  ActiveAgents::Telemetry.configure do |config|
    # Unset, the endpoint is the hosted platform (Configuration::DEFAULT_ENDPOINT).
    # A self-hosted dashboard ingests at "<mount>/api/traces", e.g.
    # https://dashboard.example.com/activeagents/api/traces.
    config.endpoint     = ENV["ACTIVEAGENTS_TELEMETRY_ENDPOINT"].presence || ActiveAgents::Telemetry::Configuration::DEFAULT_ENDPOINT
    config.api_key      = ENV["ACTIVEAGENTS_API_KEY"]
    config.service_name = "billing-app"
    config.environment  = Rails.env
  end

  ActiveAgents::Telemetry::RubyLLM.subscribe!
end
```

Delivery is fire-and-forget on a background thread; a failed post is logged
under `[ActiveAgents::Telemetry]` and never raises into a request.

### One initializer, both topologies

Most apps want the same-app dashboard while developing and the hosted
platform (or a fleet sink) once deployed. Branch on the environment:

```ruby
# config/initializers/ruby_llm_telemetry.rb
ActiveAgents::Telemetry.configure do |config|
  config.service_name = "billing-app"
  config.environment  = Rails.env

  if Rails.env.development?
    config.local_store = lambda do |trace, sdk|
      model = ActionAgent.trace_model
      next if model.exists?(trace_id: trace["trace_id"])

      model.create_from_payload(trace, sdk)
    end
  else
    config.api_key = ENV["ACTIVEAGENTS_API_KEY"]
  end
end

ActiveAgents::Telemetry::RubyLLM.subscribe! if Rails.env.development? || ENV["ACTIVEAGENTS_API_KEY"].present?
```

With this shape the engine can be mounted in development only
(`mount ActionAgent::Engine => "/activeagents" if Rails.env.development?`),
which keeps captured prompts off deployed hosts until you have decided how
to handle them.

## 4. Name your traffic

RubyLLM carries no application identity on its instrumentation payload —
neither a `RubyLLM::Agent` subclass nor an `acts_as_chat` record reaches the
instrumenter — so unattributed traffic reports as `RubyLLM::Chat.chat`.
Three ways to name it, in order of precision:

```ruby
# 1. Per call site. A turn keeps the scope it started under.
ActiveAgents::Telemetry::RubyLLM.with_agent("SupportBot", action: "respond") do
  chat.ask(question)
end

# 2. Every RubyLLM::Agent subclass, by class name.
module AgentTelemetryAttribution
  def ask(...) = ActiveAgents::Telemetry::RubyLLM.with_agent(self.class.name, action: "ask") { super }
end
RubyLLM::Agent.prepend(AgentTelemetryAttribution)

# 3. From the event payload, for traffic no scope reaches.
ActiveAgents::Telemetry::RubyLLM.subscribe!(
  agent_resolver: ->(payload) { { name: "SupportBot", action: payload[:tools].present? ? "respond" : "summarize" } }
)
```

An enclosing `with_agent` scope wins over the resolver. The resolver sees
**every** RubyLLM turn in the process — background jobs, rake tasks, and
features added after it was written — so derive the name from the payload
rather than assuming one caller. A resolver that hardcodes a name labels
everything that name.

## 5. Content capture

By default a trace carries names, timings, token counts and error messages,
not text. Enable `capture_bodies` to add the prompt, the system
instructions, the completion, and each tool's arguments and result:

```ruby
config.capture_bodies = ENV["ACTIVEAGENTS_CAPTURE_CONTENT"] == "1"
```

Each captured value is truncated to 4,000 characters. That is a cap on trace
size, not a redaction boundary: a tool result that names a customer still
names them within its first 4,000 characters. `redact_attributes` scrubs
span attributes whose key matches a list (`password`, `api_key`, ...), by
key name only. Treat capture as a development affordance, and make the
data-handling decision before enabling it where the dashboard is reachable.

## 6. Verify

Make one chat call from the app, then open `<mount>/traces` (or
`<mount>/console/traces`, the server-rendered view). Check three things on
the trace: the root span is named for your agent rather than
`RubyLLM::Chat`, the `llm` span carries input and output tokens, and each
tool the model called has its own span.

Asserting on the stored row from a test or `rails runner`? Both run inside
Rails' executor with the query cache on, so a repeated
`ActionAgent::TelemetryTrace.count` returns its first answer. Read it with
`ActionAgent::TelemetryTrace.uncached { ActionAgent::TelemetryTrace.count }`.

## Troubleshooting

- **No traces.** The reporter delivers only when it is configured: an
  `endpoint` plus an `api_key`, or a `local_store`. Then check that
  `subscribe!` ran, and — outside Rails — that `RubyLLM.config.instrumenter`
  is set. Failures are logged as `[ActiveAgents::Telemetry] ...`.
- **403 outside development.** Set `config.authentication_method`.
- **500 on `<mount>/traces` — `Could not find table 'active_agent_agents'`.**
  The install was `--traces_only`. Run `rails generate action_agent:install`
  again without the flag (it skips what already exists) and migrate, or use
  `<mount>/console/traces`.
- **401 from ingest.** The adapter's `api_key` does not match the dashboard's
  `ingest_api_key`.
- **Dashboard renders blank; `action_agent.js` and `action_agent.css` 404.**
  The host has no asset pipeline. Add propshaft (or, on an API-only app,
  re-enable the asset middleware).
- **`assets:precompile` aborts in `action_agent.css`.** The dashboard's
  stylesheet uses CSS Color 4 relative colors (`rgb(from red r g b)`), which
  SassC cannot parse, so a Sprockets host with `css_compressor = :sass`
  fails on it. The file ships minified already; pass it through:

  ```ruby
  # config/initializers/action_agent.rb
  class ActionAgentAwareCssCompressor
    def self.call(input)
      return { data: input[:data] } if input[:name] == "action_agent"

      Sprockets::SassCompressor.call(input)
    end
  end
  Rails.application.config.assets.css_compressor = ActionAgentAwareCssCompressor
  ```

- **Every trace is `RubyLLM::Chat.chat`.** See [Name your traffic](#_4-name-your-traffic).
- **Token counts are 0 on RubyLLM 2.x.** Adapter 0.3.0 reads only the 1.x
  per-message token readers, which 2.0 moved to `message.tokens`. Upgrade to
  `activeagents-telemetry-ruby_llm` 0.3.1 or later, which reads the 2.x
  payload's `tokens`.
- **A tool call is missing from its trace.** Concurrent tool execution runs
  tools off the instrumented thread and is not captured; sequential
  execution, RubyLLM's default, is. Embeddings, images, moderation, speech
  and transcription are not reported yet.

## Operating the dashboard

Retention, database portability, subdomain mounts and multi-tenant mode are
the same for a dashboard fed by RubyLLM apps as for one fed by
`ActiveAgent::Base` apps — see
[Self-Hosted Dashboard](/framework/self-hosted-observability#operations).
With a full (not `--traces_only`) install, set
`ActionAgent.execution_enabled = false` to keep the mount a read-only
observability surface.

## Related

- [Self-Hosted Dashboard](/framework/self-hosted-observability) — deploying the engine for a team or a fleet
- [Telemetry](/framework/telemetry) — the trace format and the framework's own reporting
- [RubyLLM Provider](/providers/ruby_llm) — running `ActiveAgent::Base` agents through RubyLLM instead
- [activeagents-telemetry](https://github.com/activeagents/activeagents-telemetry) — the adapter's README and turn semantics
