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
end
```

Once `user_class` (or `account_class`) is set, a request whose owner does not
resolve sees nothing rather than everything. If a signed-in user gets an empty
dashboard, the resolver above returned `nil`.

Code sessions hand an agent, with what its evaluations found, to a coding
agent (Claude Code, Codex CLI, Copilot CLI, or an open-source agent) inside a
[code-on-incus](https://github.com/mensfeld/code-on-incus) container that has
a checkout of your repository. The engine ships an in-memory mock so the view
works without infrastructure; the real backend needs an Incus host with `coi`:

```ruby
ActionAgent.configure do |config|
  config.code_session_backend = "code_on_incus"          # default :mock
  config.code_on_incus.ssh_target = ENV["COI_SSH_TARGET"] # nil when coi runs on this host
  config.github_token_resolver = ->(owner, session) { owner.github_token }
end
```

See [Code Sessions](https://docs.activeagents.ai/framework/code-sessions) for
the GitHub access modes, the brief and the security notes.

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
