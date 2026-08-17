# ActiveAgent - AI Code Generation Context

> This file helps AI code generation tools (GitHub Copilot, Claude Code, Cursor, Codex, etc.) understand and work with the ActiveAgent codebase effectively.

## Quick Reference

| What | Where |
|------|-------|
| Main entry point | `lib/active_agent.rb` |
| Base agent class | `lib/active_agent/base.rb` |
| Provider implementations | `lib/active_agent/providers/` |
| Agent concerns/mixins | `lib/active_agent/concerns/` |
| Agent-as-tool delegation | `lib/active_agent/delegation/` |
| Rails generators | `lib/generators/active_agent/` |
| Dashboard engine (`actionagent` gem) | `actionagent/` |
| Dashboard React source | `actionagent/frontend/` |
| Test suite | `test/` |
| Test Rails app | `test/dummy/` |
| Documentation source | `docs/` |

## Architecture Overview

ActiveAgent extends Rails MVC patterns to AI interactions:

```
Rails Pattern          →    ActiveAgent Pattern
Controllers            →    Agents (AI logic handlers)
Actions                →    Agent methods (return Generation objects)
Views                  →    Templates (ERB prompts in app/views/agents/)
```

### Core Classes

1. **`ActiveAgent::Base`** - Base class all agents inherit from
2. **`ActiveAgent::Generation`** - Lazy execution wrapper (like ActionMailer::MessageDelivery)
3. **`ActiveAgent::Providers::BaseProvider`** - Abstract base for LLM providers

### Execution Flow

```ruby
# 1. Agent method is called → returns Generation (lazy)
generation = MyAgent.action_name

# 2. Execution happens only when:
generation.generate_now   # Synchronous
generation.prompt_later   # Background job (ActiveJob)
```

## Key Patterns

### Creating an Agent

```ruby
class MyAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"

  # Agent actions return Generation objects
  def analyze(text)
    @text = text  # Available in templates
    prompt(
      message: "Analyze this text",
      tools: [{
        name: "search",
        description: "Search for information",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string", description: "Search query" }
          },
          required: ["query"]
        }
      }]
    )
  end

  # Tool method - name must match tool's `name` field
  def search(query:)
    SearchService.search(query)
  end
end
```

### Template Structure

Templates live in `app/views/agents/{name}/`, where `{name}` is the class name
underscored with the `_agent` suffix dropped — `TravelAgent` looks in
`app/views/agents/travel/` (`_prefixes` in `lib/active_agent/concerns/view.rb`
also searches the full underscored class name, `app/views/travel_agent/`):
- `instructions.md` - System prompt (shared across actions); `.md.erb` works too
- `{action_name}.md.erb` - Action-specific prompt template

### Provider Configuration

In `config/active_agent.yml`:
```yaml
development:
  openai:
    service: "OpenAI"
    access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
    model: "gpt-4o-mini"
```

## Common Tasks

### Adding a New Agent

```bash
rails generate active_agent:agent AgentName action1 action2
```

Creates (the view directory drops the `_agent` suffix, the agent file keeps it):
- `app/agents/agent_name_agent.rb`
- `app/views/agents/agent_name/instructions.md`
- `app/views/agents/agent_name/action1.md.erb`
- `app/views/agents/agent_name/action2.md.erb`
- `test/agents/agent_name_agent_test.rb` and
  `test/docs/previews/agent_name_agent_preview.rb`

### Adding a Tool to an Agent

Tools are defined as hashes passed to `prompt()` and matched to methods by name:

```ruby
class MyAgent < ApplicationAgent
  generate_with :openai

  def my_action
    prompt(
      message: "Do something",
      tools: [{
        name: "my_tool",
        description: "Does something useful",
        parameters: {
          type: "object",
          properties: {
            param1: { type: "string", description: "First param" },
            param2: { type: "string", description: "Optional param" }
          },
          required: ["param1"]
        }
      }]
    )
  end

  # Method name matches tool's `name` - called automatically by LLM
  def my_tool(param1:, param2: "default")
    { result: "data" }
  end
end
```

For reusable tools across agents, use a module:

```ruby
module MyTools
  SEARCH_TOOL = {
    name: "search",
    description: "Search for data",
    parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] }
  }

  def search(query:)
    SearchService.find(query)
  end
end

class MyAgent < ApplicationAgent
  include MyTools

  def find_info
    prompt(message: "Find X", tools: [SEARCH_TOOL])
  end
end
```

### Delegating to Another Agent (Agent-as-Tool)

When the work behind a tool is itself an AI task, expose a sub-agent instead of a
plain method. The sub-agent declares its own contract; the caller decides what it
may spend and what runs it:

```ruby
class SummarizerAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini"

  delegation :summarize, description: "Condense a document into key points" do
    string  :text, required: true, description: "Full document text"
    integer :limit, description: "Maximum number of key points"

    returns do                      # optional: becomes the sub-agent's response_format
      string :summary, required: true
      array  :points, of: :string, required: true
    end
  end

  def summarize(text:, limit: 5)
    prompt(message: "Summarize in #{limit} points: #{text}")
  end
end

class ResearchAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"

  delegation_budget max_calls: 8, max_duration: 60          # all delegations, together

  delegate_to SummarizerAgent, budget: { max_calls: 3, timeout: 20 }
  delegate_to FactCheckAgent, as: :verify,
              backend: { provider: :anthropic, model: "claude-haiku-4-5" }

  def research(topic:)
    prompt(message: "Research #{topic}. Summarize sources before citing them.")
  end
end
```

Key points:
- `delegate_to` defines a real instance method, so `agent.summarize(text: "...")`
  runs the delegation directly — handy in tests, no model required.
- Delegated tools merge into `prompt`'s `tools:` automatically. Scope them per
  action with `delegations: false` or `delegations: [:summarize]`.
- Exhausting a budget returns `{ error: "budget_exceeded", ... }` to the calling
  model by default; pass `on_exceeded: :raise` to fail loudly instead.
- Swap `backend: :mock` in tests to run a delegation offline with the contract
  unchanged.

See `docs/actions/delegation.md` and `lib/active_agent/concerns/delegation.rb`.

### Adding a New Provider

1. Create `lib/active_agent/providers/{service}_provider.rb` defining
   `ActiveAgent::Providers::{Service}Provider` — `gemini_provider.rb` holds
   `GeminiProvider`. Subclass `BaseProvider` (`providers/_base_provider.rb`) or
   an existing provider. If it needs a client gem, call
   `require_gem!(:key, __FILE__)` at the top — the key must exist in
   `GEM_LOADERS` at the top of `_base_provider.rb` (`:anthropic`, `:openai`,
   `:ruby_llm` today), which is also where the gem's version requirement
   lives, so a new client gem means a new entry there
2. Put the supporting pieces in `lib/active_agent/providers/{service}/` — the
   shipped providers keep `options.rb`, `request.rb`, `_types.rb` and any
   transforms there rather than in one file (see `providers/anthropic/`)
3. There is no registry file to edit. `provider_load`
   (`lib/active_agent/concerns/provider.rb`) requires
   `active_agent/providers/#{service_name.underscore}_provider` and then
   const_gets `ActiveAgent::Providers::#{Service}Provider`, so the file name is
   the registration. `service_name` is the config's `service:` value, or the
   provider key camelized when the config omits it (`:openai` → `"Openai"`).
   `PROVIDER_SERVICE_NAMES_REMAPS`, in that same file, fixes only the constant
   half when that string doesn't camelize to your class name (`"Openai"` →
   `"OpenAI"`); the require still uses the un-remapped name, which is why
   `openai_provider.rb` exists next to `open_ai_provider.rb` as a one-line
   `require_relative`. A remap without that alias file is a LoadError

## File Naming Conventions

| Type | Pattern | Example |
|------|---------|---------|
| Agent class | `{name}_agent.rb` | `support_agent.rb` |
| Provider | `{name}_provider.rb` | `open_ai_provider.rb` |
| Concern | `{feature}.rb` | `streaming.rb` |
| Test | `{subject}_test.rb` | `streaming_test.rb` |

## Testing

```bash
# Run the framework's tests (bare bin/test collects test/**/*_test.rb only)
bin/test

# Run specific test file
bin/test test/path/to/test.rb

# Run tests for a specific provider
bin/test test/integration/open_ai/

# Run both trees — the framework's test/ and the engine's actionagent/test/
bundle exec rake test
```

The engine's tests live in `actionagent/test/` and are outside `bin/test`'s
default glob; the Rakefile's `test` task is what sweeps both.

### Test Fixtures

- VCR cassettes in `test/fixtures/vcr_cassettes/`
- Test agents in `test/dummy/app/agents/`
- Test templates in `test/dummy/app/views/agents/`

## Provider-Specific Notes

### OpenAI
- Supports both Chat Completions API and Responses API
- Use `api: "responses"` in config for web search, MCP, image generation
- Vision support via image URLs in messages

### Anthropic
- Use `anthropic` gem (official SDK)
- Extended thinking via `thinking: { budget_tokens: N }`
- MCP support is Beta API

### Ollama
- Uses OpenAI-compatible API (requires `openai` gem)
- Default endpoint: `http://localhost:11434`
- No API key required

### OpenRouter
- Uses OpenAI-compatible API
- Access 200+ models through single API
- Provider preferences via `provider: { order: [...] }`

### RubyLLM
- Uses `ruby_llm` gem for unified access to 15+ providers
- RubyLLM manages its own API keys via `RubyLLM.configure`
- Model ID determines which provider is used automatically
- Supports prompts, embeddings, tool calling, and streaming

## The dashboard: a second gem in this repo

This repo ships **two** gems. `activeagent` is the framework — agents,
providers, generation, telemetry reporting, and no Active Record. `actionagent`
is the dashboard: a mountable Rails engine under `actionagent/`, with its own
gemspec, holding traces and metrics, the agent builder, runs, conversations,
evaluations, scorecards, sandboxes, session recordings, and the
agents-as-MCP-server endpoint.

They are separate because the dashboard needs `activerecord` and `solid_agent`,
neither of which the framework requires — and `solid_agent` depends on
`activeagent`, so the framework could never declare that second one without a
cycle. (Both gemspecs declare `railties`; that one is not part of the split.)

| What | Where |
|------|-------|
| Gemspec | `actionagent/actionagent.gemspec` |
| Engine + configuration seams | `actionagent/lib/action_agent/engine.rb`, `actionagent/lib/action_agent.rb` |
| Routes | `actionagent/config/routes.rb` |
| Models, controllers, jobs, services, queries, serializers, views | `actionagent/app/` |
| React source (entry `index.jsx`) | `actionagent/frontend/` |
| Prebuilt JS/CSS (committed) | `actionagent/app/assets/builds/` |
| Install generator | `actionagent/lib/generators/action_agent/install_generator.rb` |
| Engine tests | `actionagent/test/` |

- Everything in the engine is namespaced `ActionAgent::` (`ActionAgent::Agent`,
  `ActionAgent::AgentRun`, `ActionAgent::AgentExecutionService`,
  `ActionAgent::TelemetryTrace`, …). The engine is a normal gem root, so Rails
  finds `app/` and `config/routes.rb` without help.
- `ActionAgent::Compatibility` keeps the pre-split names resolving with a
  deprecation, so existing initializers and already-enqueued jobs keep
  working: `ActiveAgent::Dashboard` → `ActionAgent`,
  `ActiveAgent::TelemetryTrace` → `ActionAgent::TelemetryTrace`,
  `ActiveAgent::ProcessTelemetryTracesJob` →
  `ActionAgent::ProcessTelemetryTracesJob`. It prepends a `const_missing` onto
  `ActiveAgent` rather than aliasing eagerly, so the old names don't load the
  engine's models — and drag Active Record in at boot — just by existing.
- Paths are relative to wherever the host mounts the engine (the generator
  writes `/activeagents`): `<mount>/api/...` for the JSON API, `<mount>/mcp`
  for the MCP endpoint, `<mount>/console/traces` for the server-rendered
  views; every other path outside `/api` renders the React app for
  client-side routing.
- The frontend is built with `npm run build` inside `actionagent/frontend/` and the
  output is committed, so host apps never run a JavaScript build. Initial
  state reaches React through a JSON data attribute, not Inertia.
- Host integration goes through `ActionAgent.configure` seams
  (authentication, `current_user_resolver`, `multi_tenant`,
  `table_name_prefix`, `execution_enabled`, sandbox backends, quotas); all
  are optional and unset means single-user self-hosted behaviour.

## Common Gotchas

1. **Generation is lazy** - Nothing happens until `generate_now` or `prompt_later`
2. **Tool methods need keyword arguments** - Use `def my_tool(param:)` not `def my_tool(param)`
3. **Tool name must match method name** - `name: "search"` in hash requires `def search(...)`
4. **No `tool` macro** - Tools are passed as hashes to `prompt()`, not decorated methods
5. **Templates use ERB** - Instance variables from agent are available
6. **Provider config precedence**: Runtime > Agent class > config/active_agent.yml
7. **Delegations do have a macro** - Unlike tools, sub-agents are declared with
   `delegation` (on the callee) and `delegate_to` (on the caller); the tool
   method is generated for you
8. **Delegation budgets are per generation** - The ledger lives on the agent
   instance, so there is nothing to reset between requests

## Useful Commands

```bash
# Install generator
rails generate active_agent:install

# Generate agent
rails generate active_agent:agent MyAgent action1 action2

# Install the dashboard engine (migrations, mount, initializer).
# Needs the actionagent gem — it does not come with activeagent.
bundle add actionagent
rails generate action_agent:install

# Run tests
bin/test

# Lint
bin/rubocop

# Cross-repo: this checkout against a local solid_agent (strict = no skips)
SOLID_AGENT_PATH=../solid_agent \
  BUNDLE_GEMFILE=gemfiles/solid_agent_main.gemfile \
  SOLID_AGENT_STRICT=1 \
  bin/test test/integration/solid_agent/*_test.rb \
           actionagent/test/agent_execution_service_test.rb
```

## Cross-repo testing (solid_agent)

`solid_agent` lives in its own repository, depends on this framework, and is
depended on by `actionagent` — so all three suites can be green while the
combination a user installs is broken. `test/integration/solid_agent/` runs
them together in the dummy app, against the models
`rails generate solid_agent:install` writes, using the mock provider.

- `gemfiles/solid_agent_main.gemfile` swaps the released gem for source:
  `SOLID_AGENT_PATH` (local checkout) or `SOLID_AGENT_REF` (branch/tag/SHA).
- Tests declare what they need (`requires_solid_agent`,
  `requires_solid_agent_capability`) and skip when the resolved gem lacks
  it; `SOLID_AGENT_STRICT=1` turns those skips into failures.
- CI runs both configurations (`.github/workflows/integration.yml`), and
  `release.yml` gates publishing on them. solid_agent's CI runs the same
  suite against this repo's main branch and latest release tag.
- Version skew between the two gems is handled by feature detection rather
  than a dependency-floor bump, since the floor can only move after the
  dependency ships — see `ActionAgent.solid_agent_auto_context_keyword`.

Full write-up: `docs/contributing/releasing.md`.

## Dependencies

- Ruby 3.1+
- Rails 7.2+ / 8.0+ / 8.1+
- Provider gems (optional): `openai`, `anthropic`, `ruby_llm`
- `activeagent` depends on actionpack, actionview, activesupport, activemodel,
  activejob, railties and `activeagents-telemetry` — deliberately **not**
  activerecord
- `actionagent` (optional — the dashboard) adds `activerecord` and
  `solid_agent` on top of `activeagent`. Installing the framework does not
  install it: `bundle add actionagent` before running its generator

## Links

- Documentation: https://docs.activeagents.ai
- Repository: https://github.com/activeagents/activeagent
- Changelog: CHANGELOG.md
