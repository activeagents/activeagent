# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-11-21

Major refactor with breaking changes. Complete provider rewrite. New modular architecture.

**Requirements:** Ruby 3.1+, Rails 7.0+/8.0+/8.1+
## What's Changed
* Major Framework Refactor: ActiveAgent v1.0.0 by @sirwolfgang in https://github.com/activeagents/activeagent/pull/259
* Add API gem version testing and fix Anthropic 1.14.0 compatibility by @sirwolfgang in https://github.com/activeagents/activeagent/pull/265
* Fix version compatiblity issue for vitepress by @sirwolfgang in https://github.com/activeagents/activeagent/pull/266
* Add missing API Keys by @sirwolfgang in https://github.com/activeagents/activeagent/pull/267
* Fix website links by @sirwolfgang in https://github.com/activeagents/activeagent/pull/268
* chore: remove `standard` from dev dependencies by @okuramasafumi in https://github.com/activeagents/activeagent/pull/272
* Add thread safety tests by @sirwolfgang in https://github.com/activeagents/activeagent/pull/275
* Refactor: Leverage Native Gem Types Across All Providers by @sirwolfgang in https://github.com/activeagents/activeagent/pull/271
* Improved Usage Tracking by @sirwolfgang in https://github.com/activeagents/activeagent/pull/274

## New Contributors
* @okuramasafumi made their first contribution in https://github.com/activeagents/activeagent/pull/272

**Full Changelog**: https://github.com/activeagents/activeagent/compare/v0.6.3...v1.0.0

### Added

**Universal Tools Format**
```ruby
# Single format works across all providers (Anthropic, OpenAI, OpenRouter, Ollama, Mock)
tools: [{
  name: "get_weather",
  description: "Get current weather",
  parameters: {
    type: "object",
    properties: {
      location: { type: "string", description: "City and state" }
    },
    required: ["location"]
  }
}]

# Tool choice normalization
tool_choice: "auto"                   # Let model decide
tool_choice: "required"               # Force tool use
tool_choice: { name: "get_weather" }  # Force specific tool
```

Automatic conversion to provider-specific formats. Old formats still work (backward compatible).

**Model Context Protocol (MCP) Support**
```ruby
# Universal MCP format works across providers (Anthropic, OpenAI)
class MyAgent < ActiveAgent::Base
  generate_with :anthropic, model: "claude-haiku-4-5"

  def research
    prompt(
      message: "Research AI developments",
      mcps: [{
        name: "github",
        url: "https://api.githubcopilot.com/mcp/",
        authorization: ENV["GITHUB_MCP_TOKEN"]
      }]
    )
  end
end
```

- Common format: `{name: "server", url: "https://...", authorization: "token"}`
- Auto-converts to provider native formats
- Anthropic: Beta API support, up to 20 servers per request
- OpenAI: Responses API with pre-built connectors (Dropbox, Google Drive, etc.)
- Backwards compatible: accepts both `mcps` and `mcp_servers` parameters
- Comprehensive documentation with tested examples
- Full VCR test coverage with real MCP endpoints

### Changed

- Shared `ToolChoiceClearing` concern eliminates duplication across providers

### Breaking Changes

#### 1. Update Provider Gems

```ruby
# Gemfile - Remove unofficial gems
gem "ruby-openai"
gem "ruby-anthropic"

# Add official provider SDKs
gem "openai"      # Official OpenAI SDK
gem "anthropic"   # Official Anthropic SDK
```

Run `bundle install` after updating.

#### 2. Update Base Class

```ruby
# Before
class MyAgent < ActiveAgent::ActionPrompt::Base
end

# After
class MyAgent < ActiveAgent::Base
end
```

#### 3. Configure Providers

```ruby
# Before - options wrapped in options key
class MyAgent < ActiveAgent::Base
  def chat
    prompt(message: "Hello", options: { temperature: 0.7 })
  end
end

# After - options passed directly (at class or call level)
class MyAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini", temperature: 0.7

  def chat
    prompt("Hello")  # Uses class-level config
  end

  def chat_creative
    prompt("Hello", temperature: 1.0)  # Override per-call
  end
end
```

#### 4. Update Custom Providers (if any)

```ruby
# Before
module ActiveAgent::GenerationProvider
  class CustomProvider < Base
  end
end

# After
module ActiveAgent::Providers
  class CustomProvider < BaseProvider
  end
end
```

#### 5. Update Generator Commands

```bash
# Before
rails g active_agent MyAgent action

# After
rails g active_agent:agent MyAgent action
```

#### 6. Remove Framework Retry Config

```ruby
# Remove from config/initializers/activeagent.rb
ActiveAgent.configure do |config|
  config.retries = true
  config.retries_count = 5
end

# Use provider-specific settings in config/active_agent.yml
openai:
  service: "OpenAI"
  max_retries: 5
  timeout: 600.0
```

Template paths:
- `app/views/agents/{agent}/instructions.md` (no `.erb` extension by default for instructions)
- `app/views/agents/{agent}/{action}.md.erb`

### Added

**Mock Provider for Testing**
```ruby
class MyAgent < ActiveAgent::Base
  generate_with :mock
end

response = MyAgent.prompt("Test").generate_now
# Returns predictable responses without API calls
```

**Mixed Provider Support**
```ruby
class MyAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini"
  embed_with :anthropic, model: "claude-3-5-sonnet-20241022"
end
```

**Prompt Previews**
```ruby
preview = MyAgent.prompt("Hello").prompt_preview
# Shows instructions, messages, tools before execution
```

**Callback Lifecycle**
- `before_generation`, `after_generation`, `around_generation`
- `before_prompt`, `after_prompt`, `around_prompt`
- `before_embed`, `after_embed`, `around_embed`
- `on_stream_open`, `on_stream`, `on_stream_close`
- Rails-style callback control: `prepend_*`, `skip_*`, `append_*`

**Multi-Input Embeddings**
```ruby
response = MyAgent.embed(inputs: ["Text 1", "Text 2"]).embed_now
vectors = response.data.map { |d| d[:embedding] }
```

**Normalized Usage Statistics**
```ruby
response = MyAgent.prompt("Hello").generate_now

# Works across all providers
response.usage.input_tokens
response.usage.output_tokens
response.usage.total_tokens

# Provider-specific fields when available
response.usage.cached_tokens      # OpenAI, Anthropic
response.usage.reasoning_tokens   # OpenAI o1 models
response.usage.service_tier       # Anthropic
```

**Enhanced Instrumentation for APM Integration**
- Unified event structure: `prompt.active_agent` and `embed.active_agent` (top-level) plus `prompt.provider.active_agent` and `embed.provider.active_agent` (per-API-call)
- Event payloads include comprehensive data for monitoring tools (New Relic, DataDog, etc.):
  - Request parameters: `model`, `temperature`, `max_tokens`, `top_p`, `stream`, `message_count`, `has_tools`
  - Usage data: `input_tokens`, `output_tokens`, `total_tokens`, `cached_tokens`, `reasoning_tokens`, `audio_tokens`, `cache_creation_tokens` (critical for cost tracking)
  - Response metadata: `finish_reason`, `response_model`, `response_id`, `embedding_count`
- Top-level events report cumulative usage across all API calls in multi-turn conversations
- Provider-level events report per-call usage for granular tracking

**Multi-Turn Usage Tracking**
- `response.usage` now returns cumulative token counts across all API calls during tool calling
- New `response.usages` array contains individual usage objects from each API call
- `Usage` objects support addition: `usage1 + usage2` for combining statistics

**Provider Enhancements**
- OpenAI Responses API: `api: :responses` or `api: :chat`
- Anthropic JSON object mode with automatic extraction
- OpenRouter: quantization, provider preferences, web search
- Flexible naming: `:openai` or `:open_ai`, `:openrouter` or `:open_router`

**Rails 8.1 Support**

**Comprehensive Documentation**
- VitePress site at docs.activeagents.ai
- All examples tested and validated

### Changed

**Provider Architecture**
- Unified `BaseProvider` interface across all providers
- Retry logic moved to provider SDKs (automatic exponential backoff)
- Migrated to official SDKs: `openai` gem and `anthropic` gem
- Type-safe options with per-provider definitions

**Configuration**
- Options configurable at class level, instance level, or per-call
- Simplified parameter handling pattern

**Requirements**
- Ruby 3.1+ (previously 3.0+)

**Testing**
- Reorganized by feature and provider integration
- All documentation examples validated

### Fixed

**Providers**
- OpenAI streaming with functions/tools
- Ollama streaming support
- Anthropic tool choice modes (`any` and `tool`)
- OpenRouter model fallback and parameter naming
- Provider gem loading errors

**Framework**
- Streaming lifecycle with function/tool calls
- Multi-tool and multi-turn conversation handling
- Options mutation during generation
- Template rendering without blocks
- Schema generator key symbolization
- Rails 8.0 and 8.1 compatibility
- Usage extraction across OpenAI/Anthropic response formats

### Removed

**Namespaces**
- `ActiveAgent::ActionPrompt` → use `ActiveAgent::Base`
- `ActiveAgent::GenerationProvider` → use `ActiveAgent::Providers`

**Configuration**
- `ActiveAgent.configuration.retries` → use provider `max_retries`
- `ActiveAgent.configuration.retries_count` → use provider `max_retries`
- `ActiveAgent.configuration.retries_on` → handled by provider SDKs

**Modules**
- `ActiveAgent::QueuedGeneration` → `Queueing` concern
- `ActiveAgent::Rescuable` → `Rescue` concern
- `ActiveAgent::Sanitizers` → moved to concerns
- `ActiveAgent::PromptHelper` → moved to concerns

## [0.3.2] - 2025-04-15

### Added
- CI configuration for stable GitHub releases moving forward.
- Test coverage for core features: ActionPrompt rendering, tool calls, and embeddings.
- Enhance streaming to support tool calls during stream. Previously, streaming mode blocked tool call execution.
- Fix layout rendering bug when no block is passed and views now render correctly without requiring a block.

### Removed
- Generation Provider module and Action Prompt READMEs have been removed, but will be updated along with the main README in the next release.
