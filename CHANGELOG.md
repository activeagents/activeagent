# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - Unreleased

Major refactor: `ActionPrompt::Base` → `ActiveAgent::Base` with modular concerns pattern. Complete provider rewrite with 205 new files. Documentation rewrite with 185 organized guides.

**Stats:** 105 commits, 974 files, 185,089 insertions(+) / 30,834 deletions(-), 205 provider files, 185 documentation files, 315 new VCR cassettes, 93,805 new test lines.

**Requirements:** Ruby 3.1+, Rails 7.0+/8.0+/8.1+

### Breaking Changes

**Base class namespace:**
```ruby
# Before
class MyAgent < ActiveAgent::ActionPrompt::Base
end

# After
class MyAgent < ActiveAgent::Base
end
```

**Provider namespace:**
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

**Method signatures:**
```ruby
# Before
class MyAgent < ActiveAgent::ActionPrompt::Base
  def my_action
    prompt(message: "Hello", stream: true, options: { temperature: 0.7 })
  end
end

# After
class MyAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini", temperature: 0.7

  def my_action
    prompt("Hello, world!")
  end

  def my_action_streaming
    prompt(message: "Tell me a story", stream: true)
  end
end
```

**Template paths:**
- Instructions: `app/views/agents/{agent_name_without_agent_suffix}/instructions.{md,text}.erb`
- Messages: `app/views/agents/{agent_name_without_agent_suffix}/{action_name}.{md,text}.erb`
- Schemas: `app/views/agents/{agent_name_without_agent_suffix}/{action_name}.json`

**Generator changes:**
- Command: `rails g active_agent` → `rails g active_agent:agent`
- Now creates `instructions.md.erb` by default
- Markdown is default format (use `--format=text` for plain text)
- New flags: `--json-schema`, `--json-object`

**Migration Guide:**
- See breaking changes above for code migration examples
- Update base class inheritance and provider namespaces
- Move to new `generate_with` configuration pattern
- Update template paths to new structure
- Change generator command from `rails g active_agent` to `rails g active_agent:agent`
- **Update provider gems in your Gemfile:**
  ```ruby
  # Remove these
  gem "ruby-openai"
  gem "ruby-anthropic"

  # Add these
  gem "openai"          # Official OpenAI SDK
  gem "anthropic"       # Official Anthropic SDK
  ```
- **Migrate from framework retries to provider-native retries:**
  ```ruby
  # Remove framework retry configuration
  # ActiveAgent.configure do |config|
  #   config.retries = true
  #   config.retries_count = 5
  # end

  # Use provider-specific retry settings instead
  # config/activeagent.yml
  openai:
    service: "OpenAI"
    max_retries: 5          # Provider SDK handles retries
    timeout: 600.0

  anthropic:
    service: "Anthropic"
    max_retries: 5
    timeout: 600.0
  ```

### Addedbu

**Core Framework:**
- `ActiveAgent::Base` inheriting from `AbstractController::Base`
- Modular concerns: `Callbacks`, `Observers`, `Parameterized`, `Preview`, `Provider`, `Queueing`, `Rescue`, `Streaming`, `Tooling`, `View`
- Template loading: Instructions from `instructions.{md,text}.erb`, messages from `{action_name}.{md,text}.erb`, schemas from `{action_name}.json`
- Five ways to set instructions: default template, inline string, custom template with locals, method reference, array
- Dynamic template bindings with `params`, instance variables, local variables

**Providers:**
- `ActiveAgent::Providers::MockProvider` for testing without API calls
- Mixed provider support: `generate_with` + `embed_with` for different providers per feature
- OpenAI Responses API support: Configure with `api: :responses` or `api: :chat`
- Anthropic JSON object emulation: Injects prefilled assistant message, extracts JSON
- OpenRouter enhancements: Provider preferences, quantization (int4/int8/fp6/fp8/fp16), PDF plugins, transforms, user tracking, web search
- Native format support: Provider-native formats pass through unmodified
- Flexible provider naming: Both `:openai`/`:open_ai` and `:openrouter`/`:open_router`
- Per-provider type definitions in `_types.rb` files
- Comprehensive retry mechanisms with exponential backoff

**Callbacks:**
- `before_prompt`, `after_prompt`, `around_prompt` (with `*_generation` aliases for backward compatibility)
- `before_embed`, `after_embed`, `around_embed` for embedding lifecycle
- `on_stream_open`, `on_stream`, `on_stream_close` with optional `StreamChunk` parameter
- `prepend_*`, `skip_*`, `append_*` variants for all callback types (matching Rails controller callbacks)

**Embeddings:**
- Redesigned API supporting provider mixing
- Multi-input embedding: `embed(inputs: ["Text 1", "Text 2"])`
- Provider-specific options: `dimensions`, `encoding_format`

**Prompt Previews:**
- `prompt_preview` (alias: `preview_prompt`) for debugging prompts before execution
- Markdown-formatted output with YAML frontmatter containing request parameters
- Shows instructions, messages, and tool definitions
- Useful for testing, debugging, and cache key generation

**Error Handling:**
- `rescue_from` integration with agent context
- Exception handler concern for agent-level error handling
- Provider-native retry mechanisms (OpenAI, Anthropic SDKs)

**Documentation:**
- 185 documentation files in VitePress site
- Organized structure with index files: `framework/`, `agents/`, `actions/`, `providers/`, `examples/`

**Testing:**
- `test/integration/` with provider-specific tests
- `test/features/` for callbacks, parameterization, providers, rescue, streaming, views
- `test/docs/` validating all documentation examples
- 315 new VCR cassettes (324 total)
- Schema generator tests
- Retry mechanism tests

**Infrastructure:**
- Rails 8.1 support
- Pnpm workspace configuration
- `.tool-versions` file

### Changed

**Providers:**
- Complete rewrite: 205 new provider files
- Unified `BaseProvider` interface across OpenAI, Anthropic, Ollama, OpenRouter
- Retry logic: Now uses provider SDK native retries (ruby-openai, anthropic-rb)
- Provider SDKs handle exponential backoff, rate limits, jitter automatically
- Type-safe options with structured definitions per provider
- **Migrated to official provider gems:**
  - OpenAI: `ruby-openai ~> 8.3` → `openai ~> 0.34` (unofficial 3rd-party → official OpenAI SDK)
  - Anthropic: `ruby-anthropic ~> 0.4.2` → `anthropic ~> 1.12` (unofficial 3rd-party → official Anthropic SDK)

**Architecture:**
- Parameter handling: Simplified to 3-step Collect → Merge → Translate pattern
- Method organization: Files reorganized in call stack order
- Configuration structure: Root-level provider keys with `service:` attribute

**Testing:**
- Test organization: Flat structure → organized by feature/integration
- 93,805 new test lines (vs 20,722 removed)
- All documentation examples now tested

**Requirements:**
- Ruby: 3.0+ → 3.1+ (aligned with Rails 8)

**Options:**
- Can be configured at class level, overridden at instance level, or passed to individual `prompt()` calls

### Fixed

**Providers:**
- OpenRouter model/models fallback construction
- OpenRouter max_price parameter naming
- OpenAI Chat API streaming with functions/tools
- Ollama streaming support
- Anthropic tool choice modes (`any` and `tool`)
- Provider-specific parameter merge conflicts
- Provider gem loading error messages

**Framework:**
- Streaming lifecycle: Function/tool calls no longer signal finish/close multiple times
- Multi-tool and multi-iteration support
- Conflicting global configuration variables
- Options mutation during generation
- Template rendering without blocks
- Schema generator key symbolization for consistent hash key types
- SchemaGenerator now consistently wraps schemas in `{ name:, schema:, strict: }` format regardless of `strict:` option
- Rails 8 and 8.1 compatibility
- Multi-turn conversation handling

**Infrastructure:**
- Gem loading for optional dependencies
- Gem version constraints (fixed to use majors instead of minors)
- Rails inflections for Active Agent terminology
- Credentials encryption key management

### Removed

**Namespaces:**
- `ActiveAgent::ActionPrompt` (replaced by `ActiveAgent::Base`)
- `ActiveAgent::GenerationProvider` (replaced by `ActiveAgent::Providers`)

**Modules:**
- `ActiveAgent::QueuedGeneration` (replaced by `Queueing` concern)
- `ActiveAgent::Rescuable` (replaced by `Rescue` concern)
- `ActiveAgent::Sanitizers` (functionality moved to concerns)
- `ActiveAgent::PromptHelper` (functionality moved to concerns)
- `ActiveAgent::Providers::Retries` (replaced by `ExceptionHandler` - retry logic now in provider SDKs)

**Configuration:**
- `ActiveAgent.configuration.retries` (use provider SDK `max_retries` instead)
- `ActiveAgent.configuration.retries_count` (use provider SDK `max_retries` instead)
- `ActiveAgent.configuration.retries_on` (provider SDKs handle error classes automatically)
- Framework-level retry configuration (moved to provider-native implementations)

**Directories:**
- `lib/active_agent/action_prompt/`
- `lib/active_agent/generation_provider/`
- Top-level `callbacks.rb` and `parameterized.rb` (moved to `concerns/`)

**Documentation:**
- Old structure in `docs/docs/`
- `CLAUDE.md` (migrated to documentation site)
- `example_file_mapping.md`
- Provider-specific READMEs (consolidated)

**Tests:**
- Old agent-specific tests (consolidated into feature/integration)
- Generation provider unit tests (replaced by provider integration tests)
- Obsolete test fixtures and cassettes

### Performance

- Lazy autoloading for faster boot times
- Modular provider architecture reduces memory footprint
- Deferred option merging
- Optimized VCR cassette loading
- Mock provider enables near-instant testing

## [0.3.2] - 2025-04-15

### Added
- CI configuration for stable GitHub releases moving forward.
- Test coverage for core features: ActionPrompt rendering, tool calls, and embeddings.
- Enhance streaming to support tool calls during stream. Previously, streaming mode blocked tool call execution.
- Fix layout rendering bug when no block is passed and views now render correctly without requiring a block.

### Removed
- Generation Provider module and Action Prompt READMEs have been removed, but will be updated along with the main README in the next release.
