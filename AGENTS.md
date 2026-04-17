# ActiveAgent - AI Code Generation Context

> This file helps AI code generation tools (GitHub Copilot, Claude Code, Cursor, Codex, etc.) understand and work with the ActiveAgent codebase effectively.

## Quick Reference

| What | Where |
|------|-------|
| Main entry point | `lib/active_agent.rb` |
| Base agent class | `lib/active_agent/base.rb` |
| Provider implementations | `lib/active_agent/providers/` |
| Agent concerns/mixins | `lib/active_agent/concerns/` |
| Rails generators | `lib/generators/active_agent/` |
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

Templates live in `app/views/agents/{agent_name}/`:
- `instructions.md.erb` - System prompt (shared across actions)
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

Creates:
- `app/agents/agent_name_agent.rb`
- `app/views/agents/agent_name_agent/instructions.md.erb`
- `app/views/agents/agent_name_agent/action1.md.erb`
- `app/views/agents/agent_name_agent/action2.md.erb`

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

### Adding a New Provider

1. Create `lib/active_agent/providers/my_provider.rb`
2. Create `lib/active_agent/providers/my_provider/` directory with:
   - `client.rb` - API client wrapper
   - `request.rb` - Request building
   - `response.rb` - Response parsing
3. Register in `lib/active_agent/providers.rb`

## File Naming Conventions

| Type | Pattern | Example |
|------|---------|---------|
| Agent class | `{name}_agent.rb` | `support_agent.rb` |
| Provider | `{name}_provider.rb` | `open_ai_provider.rb` |
| Concern | `{feature}.rb` | `streaming.rb` |
| Test | `{subject}_test.rb` | `streaming_test.rb` |

## Testing

```bash
# Run all tests
bin/test

# Run specific test file
bin/test test/path/to/test.rb

# Run tests for a specific provider
bin/test test/integration/open_ai/
```

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

## Common Gotchas

1. **Generation is lazy** - Nothing happens until `generate_now` or `prompt_later`
2. **Tool methods need keyword arguments** - Use `def my_tool(param:)` not `def my_tool(param)`
3. **Tool name must match method name** - `name: "search"` in hash requires `def search(...)`
4. **No `tool` macro** - Tools are passed as hashes to `prompt()`, not decorated methods
5. **Templates use ERB** - Instance variables from agent are available
6. **Provider config precedence**: Runtime > Agent class > config/active_agent.yml

## Useful Commands

```bash
# Install generator
rails generate active_agent:install

# Generate agent
rails generate active_agent:agent MyAgent action1 action2

# Run tests
bin/test

# Lint
bin/rubocop
```

## Dependencies

- Ruby 3.1+
- Rails 7.2+ / 8.0+ / 8.1+
- Provider gems (optional): `openai`, `anthropic`, `ruby_llm`

## Links

- Documentation: https://docs.activeagents.ai
- Repository: https://github.com/activeagents/activeagent
- Changelog: CHANGELOG.md
