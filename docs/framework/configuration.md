---
title: Configuration
description: Flexible configuration for framework-level settings and provider-specific options. Configure retry strategies, logging, and multiple AI providers with environment-specific settings.
---
# {{ $frontmatter.title }}

ActiveAgent provides flexible configuration options for both framework-level settings and provider-specific configurations. Configure global behavior like retry strategies and logging, or define multiple AI providers with environment-specific settings.

## Global Settings

Configure framework-level behavior using `ActiveAgent.configure`:

```ruby
ActiveAgent.configure do |config|
  # Retry configuration (see Retries documentation for details)
  config.retries = true
  config.retries_count = 3

  # Logging (non-Rails only)
  config.logger = Logger.new(STDOUT)
  config.logger.level = Logger::INFO
end
```

### Reference

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `retries` | Boolean, Proc | `true` | Retry strategy for failed requests |
| `retries_count` | Integer | `3` | Maximum retry attempts |
| `retries_on` | Array\<Class\> | Network errors | Exception classes that trigger retries |
| `logger` | Logger | `Rails.logger` | Logger instance (Rails auto-configured) |


## Flow and Precedence

ActiveAgent applies configuration settings in a hierarchical order, where each level can override the previous one. Understanding this flow helps you control exactly how your agents behave at different stages.

### Configuration Hierarchy

Settings are applied in the following order, from lowest to highest precedence:

1. **Global Root Settings** - Base configuration defined in your YAML file or set on the configuration object
2. **Environment-Specific Settings** - Override root settings based on the current environment (development, test, production)
3. **Agent-Level Settings** - Configuration provided to `generate_with` or `embed_with` in your agent class
4. **Request-Level Settings** - Settings passed when calling `prompt`, `embed`, or `generate_with` on an instance
5. **Generation Call** - Final settings applied at the moment `prompt_now` or `embed_now` is triggered

Each level overrides only the specific settings it defines, leaving others unchanged from previous levels.

### Configuration Flow Example

```yaml
# config/active_agent.yml
# 1. Global root settings
openai: &openai
  service: "OpenAI"
  access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
  model: "gpt-4o"
  temperature: 0.5

# 2. Environment-specific overrides
development:
  openai:
    <<: *openai
    model: "gpt-4o-mini"      # Overrides model for development
    temperature: 0.7           # Overrides temperature for development
```

```ruby
# 3. Agent-level configuration
class MyAgent < ApplicationAgent
  generate_with :openai, temperature: 0.8  # Overrides temperature from YAML
end

# 4. Request-level configuration
agent = MyAgent.with(message: "Hello")
  .prompt_context
  .generate_with(:openai, model: "gpt-4o", max_tokens: 1000)  # Overrides model, adds max_tokens

# 5. Generation triggered
result = agent.prompt_now  # Uses: openai service, gpt-4o model, 0.8 temperature, 1000 max_tokens
```

### Precedence in Action

Given the example above, here's how settings are resolved:

| Setting | Root | Environment | Agent Class | Request | Final Value |
|---------|------|-------------|-------------|---------|-------------|
| `service` | `"OpenAI"` | - | - | `"OpenAI"` | `"OpenAI"` |
| `model` | `"gpt-4o"` | `"gpt-4o-mini"` | - | `"gpt-4o"` | `"gpt-4o"` |
| `temperature` | `0.5` | `0.7` | `0.8` | - | `0.8` |
| `max_tokens` | - | - | - | `1000` | `1000` |
| `access_token` | `"sk-..."` | - | - | - | `"sk-..."` |

### Practical Applications

**Development vs Production Models:**
```yaml
openai: &openai
  service: "OpenAI"
  access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
  model: "gpt-4o"

development:
  openai:
    <<: *openai
    model: "gpt-4o-mini"  # Cheaper for development

production:
  openai:
    <<: *openai
    model: "gpt-4o"  # Full capability for production
```

**Agent-Specific Defaults:**
```ruby
class CreativeAgent < ApplicationAgent
  generate_with :openai, temperature: 0.9  # High creativity by default
end

class PreciseAgent < ApplicationAgent
  generate_with :openai, temperature: 0.2  # Low temperature for consistency
end
```

**Request-Level Overrides:**
```ruby
class CreativeAgent < ApplicationAgent
  generate_with :openai, temperature: 0.9  # High creativity by default

  # Low temperature takes effect
  def imagine
    prompt(temperature: 0.3)
  end
end
```

### Key Principles

- **Explicit overrides implicit** - Specifically set values always win over inherited ones
- **Closer to execution wins** - Settings applied closer to `prompt_now` take precedence
- **Partial overrides** - You only need to specify the settings you want to change
- **Environment awareness** - Environment-specific settings automatically apply without code changes

## Providers

### YAML Configuration File

The recommended way to configure providers is using a YAML file with environment-specific sections. This approach keeps API keys secure, supports multiple providers, and allows different settings per environment.

Create `config/active_agent.yml`:

<<< @/../test/dummy/config/active_agent.yml#config_anchors {yaml:line-numbers}

<<< @/../test/dummy/config/active_agent.yml#config_development {yaml:line-numbers}

**Key features:**
- **YAML anchors** (`&openai`, `*openai`) - Reuse common configuration blocks
- **ERB templates** - Access Rails credentials and environment variables
- **Environment sections** - Different settings for development, test, production
- **Provider-specific settings** - Configure API keys, models, temperatures, etc.

### Loading Configuration

Load the YAML configuration in your Rails initializer:

```ruby
# config/initializers/activeagent.rb
ActiveAgent.configuration_load(Rails.root.join("config/active_agent.yml"))
```

The Railtie automatically loads `config/active_agent.yml` if it exists, so you typically don't need to do this manually in Rails applications.

### Storing API Keys

**Best practice:** Store API keys in Rails credentials, not directly in YAML files.

```bash
# Edit credentials
rails credentials:edit

# Add provider keys
openai:
  access_token: sk-...

anthropic:
  access_token: sk-ant-...

open_router:
  access_token: sk-or-...
```

Reference in `active_agent.yml`:

```yaml
openai: &openai
  service: "OpenAI"
  access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
```

### Reference

Common settings available across all providers:

| Setting | Type | Required | Description |
|---------|------|----------|-------------|
| `service` | String | Yes | Provider class name (OpenAI, Anthropic, OpenRouter, Ollama, RubyLLM, Mock) |
| `access_token` / `api_key` | String | Yes* | API authentication key |
| `model` | String | Yes* | Model identifier for the LLM to use |
| `temperature` | Float | No | Randomness control (0.0-2.0, default varies by provider) |
| `max_tokens` | Integer | No | Maximum tokens in response |

\* Required by most providers. Some providers like Ollama may not require authentication for local instances, and may have default models configured.

**Provider-specific settings:** Each provider supports additional configuration options beyond these common settings. For complete details on available settings, environment variables, and provider-specific features, see:

- **[Anthropic Provider](/providers/anthropic)** - Beta headers, base URL, retry configuration, etc.
- **[Ollama Provider](/providers/ollama)** - Host configuration for local instances
- **[OpenAI Provider](/providers/open_ai)** - Organization ID, request timeout, admin token, etc.
- **[OpenRouter Provider](/providers/open_router)** - App name, site URL, provider preferences, etc.
- **[RubyLLM Provider](/providers/ruby_llm)** - Unified API for 15+ providers via RubyLLM
- **[Mock Provider](/providers/mock)** - Testing-specific options

### Using Configured Providers

Once configured, reference providers by name in your agents:

```ruby
class MyAgent < ApplicationAgent
  generate_with :openai  # Uses settings from config/active_agent.yml
end
```

### Multiple Provider Instances

Configure multiple instances of the same provider with different settings:

```yaml
development:
  openai_fast:
    service: "OpenAI"
    access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
    model: "gpt-4o-mini"
    temperature: 0.7

  openai_precise:
    service: "OpenAI"
    access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
    model: "gpt-4o"
    temperature: 0.3
```

Use in agents:

```ruby
class FastAgent < ApplicationAgent
  generate_with :openai_fast
end

class PreciseAgent < ApplicationAgent
  generate_with :openai_precise
end
```

## Retrys

ActiveAgent automatically retries failed requests due to network errors. Configure retry behavior globally or provide custom retry strategies.

**Quick configuration:**

```ruby
# Enable/disable retries
config.retries = true           # Enable automatic retries (default)
config.retries = false          # Disable all retries

# Adjust retry count
config.retries_count = 5        # Maximum retry attempts (default: 3)

# Add custom exception classes
config.retries_on << CustomNetworkError
```

For advanced retry configuration including exponential backoff, custom strategies, rate limiting, and per-provider settings, see **[Retries](/framework/retries)**.

## Logging

### Rails Applications

In Rails, ActiveAgent automatically inherits logging settings from your Rails application:

- **Logger**: Uses `Rails.logger` by default
- **Log level**: Inherits from `Rails.logger.level`

Configure in your environment files:

```ruby
# config/environments/development.rb
config.log_level = :debug

# config/environments/production.rb
config.log_level = :info
```

### Non-Rails Applications

For standalone Ruby applications, configure logging manually:

```ruby
ActiveAgent.configure do |config|
  # Set up logger
  config.logger = Logger.new(STDOUT)
  config.logger.level = Logger::INFO
end
```

**Log levels:**
- `DEBUG` - All instrumentation events with full detail
- `INFO` - Important operations (API calls, completions)
- `WARN` - Errors and retries only
- `ERROR` - Only failures
- `FATAL` - Disable instrumentation logging

See [Instrumentation](/framework/instrumentation) for detailed logging and monitoring options.

## Related Documentation

- **[Retries](/framework/retries)** - Retry strategies, custom retry logic, and error handling
- **[Instrumentation](/framework/instrumentation)** - Logging, monitoring, and event tracking
- **[Rails Integration](/framework/rails)** - Rails-specific configuration and setup
- **[Testing](/framework/testing)** - Test configuration and mock providers
- **[Agents](/agents)** - How agents use configuration in generate_with
- **[Providers](/providers)** - Provider-specific features and behavior
