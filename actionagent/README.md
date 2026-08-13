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
  config.current_user_resolver    = -> (controller) { controller.send(:current_user) }
  config.current_account_resolver = -> (controller) { controller.send(:current_account) }

  # Restrict what a given owner can see.
  config.agent_scope_resolver = ->(owner) { ActionAgent::Agent.where(user: owner) }
end
```

See [the self-hosted observability guide](https://docs.activeagents.ai/framework/self-hosted-observability)
for the full list.

## Assets

The dashboard's JavaScript and CSS ship prebuilt in the gem, under
`app/assets/builds`. Host apps never run a JavaScript build — there is nothing
to install, compile or configure. The React sources live in `frontend/` in the
repository and are deliberately excluded from the packaged gem.

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
