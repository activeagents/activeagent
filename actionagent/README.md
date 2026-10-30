# Action Agent

The Active Agent dashboard, as a mountable Rails engine.

Build and run agents, read their conversations, score them with evaluations,
and watch traces, metrics and costs — served from your own database, on your
own domain.

This is a sibling gem to [`activeagent`](https://github.com/activeagents/activeagent),
released from the same repository the way `actionpack` and `actionmailer` are
released from `rails/rails`. The dependency runs one way: `actionagent` needs
`activeagent`, never the reverse. Installing the framework does not install the
dashboard, and an app that only generates with agents never loads Active
Record on its behalf.

## Install

```ruby
# Gemfile
gem "activeagent"
gem "actionagent"
```

```sh
bin/rails generate action_agent:install
bin/rails db:migrate
```

The generator copies the migrations, writes
`config/initializers/action_agent.rb`, and mounts the engine:

```ruby
# config/routes.rb
mount ActionAgent::Engine => "/activeagents"
```

Mount it wherever you like — the client-side routes are resolved relative to
the mount point, so `/activeagents`, `/admin/agents` and `/dashboard` all work.

The host needs an asset pipeline (propshaft or sprockets-rails) to serve the
prebuilt dashboard bundles — see [Assets](#assets).

### Options

| Flag | Effect |
| --- | --- |
| `--traces-only` | Install trace ingestion alone, without the agent, run and evaluation tables |
| `--multi-tenant` | Scope traces to an account (adds `account_id` to the migration) |
| `--skip-migrations` | Don't copy the migrations |
| `--skip-routes` | Don't add the mount to `routes.rb` |

## Configuration

Every integration point is a lambda or a class name, so the engine adapts to
whatever your app already calls things:

```ruby
# config/initializers/action_agent.rb
ActionAgent.configure do |config|
  config.user_class = "User"

  # Resolve the signed-in user from your own session or auth library. The
  # engine's controllers are their own base class, so your app's
  # `current_user` helper is not available on them — and a resolver that
  # calls `controller.current_user` reaches the engine's own accessor
  # rather than yours, which resolves to nobody.
  config.current_user_resolver = ->(controller) {
    User.find_by(id: controller.session[:user_id])
  }

  # Restrict what a given owner can see.
  config.agent_scope_resolver = ->(owner) { ActionAgent::Agent.where(user: owner) }

  # Put your app's own concerns on the engine's classes: a connection
  # switcher on every model, request tagging on every dashboard controller.
  config.model_concerns = ["ConnectionSwitching"]
  config.controller_concerns = ["RequestTagging"]
end
```

Once `user_class` (or `account_class`) is set, a request whose owner does not
resolve sees nothing rather than everything. If a signed-in user gets an empty
dashboard, the resolver above returned `nil`.

See [the self-hosted observability guide](https://docs.activeagents.ai/framework/self-hosted-observability)
for the full list.

## Assets

The dashboard's JavaScript and CSS ship prebuilt in the gem, under
`app/assets/builds`. Host apps never run a JavaScript build. The React sources
live in `frontend/` in the repository and are deliberately excluded from the
packaged gem.

The prebuilt bundles are served through the host app's **asset pipeline** —
propshaft (the Rails default) or sprockets-rails — which is the one
prerequisite. A `rails --api` app, or one that removed propshaft, has none:
the engine logs a warning at boot and the dashboard renders blank with
`action_agent.js` and `action_agent.css` 404ing. Add propshaft to the Gemfile
(and, for an API-only app, re-enable the asset initializer and middleware) and
the bundles are served with nothing else to configure.

## Evaluation reports

An application that runs its own evaluations publishes each report to
`POST <mount>/api/evaluation_reports` with `ActiveAgent::Evals::Publisher`,
authenticated with the ingest key. Any complete run comes back out as the
same envelope from `GET <mount>/api/evaluation_reports/:run_id`, so it can be
posted to another install; posting it back here is an identical retry.
`?format=html` or `?format=md` returns its report page or Markdown instead,
and `?download=1` an attachment. A
signed-in session reads it at
`<mount>/api/evaluations/:id/runs/:run_id/report.json`, the HTML page at
`report`, and GitHub-flavored Markdown at `report.md`, each downloadable with
`?download=1`. Inside the host app:

```bash
bin/rails action_agent:evaluations:export RUN=<run_id> FORMAT=json|html|md [FILE=path]
bin/rails action_agent:evaluations:export EVALUATION=<id> RUN=<id> FORMAT=md
bin/rails action_agent:evaluations:import FILE=run.json [ACCOUNT_ID=<id>]
```

From any machine with the `activeagent` gem, over HTTP with the ingest key
(see [Command Line](https://docs.activeagents.ai/framework/cli)):

```bash
activeagent evals report <run_id> --format json -o run.json   # or html, md
activeagent evals import run.json
```

See [Publishing an externally executed evaluation](https://docs.activeagents.ai/evals/publication)
for the envelope, the run_id a dashboard run exports under, and every response.

## Upgrading from activeagent <= 1.1.0

The dashboard used to live inside the framework gem as `ActiveAgent::Dashboard`.
The old constants still resolve and warn through the deprecator:

| Old | New |
| --- | --- |
| `ActiveAgent::Dashboard` | `ActionAgent` |
| `ActiveAgent::TelemetryTrace` | `ActionAgent::TelemetryTrace` |
| `ActiveAgent::ProcessTelemetryTracesJob` | `ActionAgent::ProcessTelemetryTracesJob` |

They are removed in the next major. Add `gem "actionagent"` to your Gemfile and
rename your references.

## License

MIT. See [LICENSE](LICENSE).
