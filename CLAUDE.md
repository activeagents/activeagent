# CLAUDE.md - Understanding ActiveAgent Repository

## Overview

ActiveAgent is a Ruby on Rails framework that brings AI-powered capabilities to Rails applications using familiar Rails patterns. It treats AI agents as controllers with enhanced generation capabilities, memory, and tooling.

### Core Concepts

1. **Agents are Controllers** - Agents inherit from `ActiveAgent::Base` and follow Rails controller patterns
2. **Actions are Tools** - Public methods in agents become tools that can interact with systems and code
3. **Prompts use Action View** - Leverages Rails' view system for rendering prompts and responses
4. **Generation Providers** - Common interface for AI providers (OpenAI, Anthropic, Ollama, etc.)

## Repository Structure

```
activeagent/
├── lib/active_agent/        # Core framework code
│   ├── base.rb              # Base agent class
│   ├── generation.rb        # Generation logic
│   ├── action_prompt/       # Prompt system components
│   └── generation_provider/ # AI provider adapters
├── test/                    # Test suite with examples
│   ├── dummy/               # Rails test app
│   └── agents/              # Agent test examples
├── docs/                    # VitePress documentation
│   ├── docs/                # Markdown documentation files
│   └── parts/examples/      # Generated example outputs
└── bin/                     # Executable scripts
```

## Documentation Process

This repository follows a strict documentation process to ensure all code examples are tested and accurate:

### Key Principles

1. **No hardcoded code blocks** - All code must come from tested files
2. **Use `<<<` imports only** - Import code from actual tested implementation and test files
3. **Test everything** - If it's in docs, it must have a test
4. **Include outputs** - Use `doc_example_output` for response examples

### Import Patterns

#### Implementation Files
```markdown
<<< @/../test/dummy/app/agents/support_agent.rb {ruby}
<<< @/../test/dummy/app/agents/support_agent.rb#5-9 {ruby:line-numbers}
```

#### Test Code with Regions

##### In test file:
```ruby
# region unique_region_name
code_to_include
# endregion unique_region_name
```
##### In docs:
```markdown
<<< @/../test/agents/support_agent_test.rb#unique_region_name {ruby:line-numbers}
```

#### Test Output Examples
```markdown
::: details Response Example
<!-- @include: @/parts/examples/test-name-test-name.md -->
:::
```

### The `doc_example_output` Method

Located in `test/test_helper.rb`, this method:
- Captures test output and formats it for documentation
- Generates files in `docs/parts/examples/` with deterministic names
- Supports Ruby objects, JSON, and response objects
- Includes metadata (source file, line number, test name)

Usage in tests:
```ruby
response = agent.generate(prompt)
doc_example_output(response)  # Generates example file
```

## Working with Documentation

### Current Branch Status
The `data-extraction-example-docs` branch is improving documentation found on docs.activeagents.ai. All code snippets should include example outputs using the `doc_example_output` method.

### Documentation Files Needing Review

Files that may still have hardcoded examples:
- `docs/docs/framework/generation-provider.md`
- `docs/docs/framework/active-agent.md`
- `docs/docs/action-prompt/actions.md`
- `docs/docs/action-prompt/messages.md`
- `docs/docs/action-prompt/prompts.md`

### Running Tests and Building Docs

1. Run tests to generate examples:
```bash
# Run all tests
bin/test

# Run specific test file
bin/test test/agents/your_agent_test.rb

# Run specific test by name pattern
bin/test test/agents/your_agent_test.rb -n "test_name_pattern"
```

2. Build and serve docs locally:
```bash
# Start development server (recommended)
bin/docs  # Starts vitepress dev server at http://localhost:5173

# Build static docs (for production)
cd docs && npm run docs:build

# Preview built docs
cd docs && npm run docs:preview
```

## Key Framework Components

### Agents
- Inherit from `ActiveAgent::Base`
- Use `generate_with` to specify AI provider
- Define actions as public instance methods
- Support callbacks (`before_action`, `after_generation`)

### Actions
- Render prompts using `prompt` method
- Support multiple content types (text, JSON, HTML)
- Can accept parameters via `with` method
- Include tool schemas in JSON views

### Generation Providers
- OpenAI, Anthropic, Ollama, OpenRouter supported
- Configured in `config/active_agent.yml`
- Support streaming, callbacks, and queued generation

### Prompts
- Built using Action View templates
- Support instructions (default, custom template, or plain text)
- Include message history and available actions
- Can be multimodal (text, images, files)

## Testing Conventions

### VCR Cassettes
- Used for recording API responses
- Keep existing cassettes committed
- Create unique names for new tests
- Ensure `test/dummy/config/master.key` is present

### Test Organization
- Agent tests in `test/agents/`
- Framework tests in respective directories
- Use regions for important test snippets
- Always call `doc_example_output` for examples

## Important Commands

```bash
# Install dependencies
bundle install

# Run all tests
bin/test

# Run specific test file
bin/test test/agents/specific_agent_test.rb

# Run specific test by name
bin/test test/agents/specific_agent_test.rb -n "test_name_pattern"

# Start documentation development server
bin/docs  # http://localhost:5173

# Build documentation for production
cd docs && npm run docs:build

# Generate new agent
rails generate active_agent:agent AgentName action1 action2
```

## Configuration

### active_agent.yml
```yaml
development:
  openai:
    access_token: <%= Rails.application.credentials.dig(:openai, :api_key) %>
    model: gpt-4o
  anthropic:
    access_token: <%= Rails.application.credentials.dig(:anthropic, :api_key) %>
    model: claude-3-5-sonnet-latest
```

### Credentials
Store API keys in Rails credentials:
```bash
rails credentials:edit
```

## Best Practices

1. **Always test code examples** - Never add untested code to docs
2. **Use regions in tests** - Makes it easy to import specific snippets
3. **Include example outputs** - Users need to see what to expect
4. **Follow Rails conventions** - ActiveAgent extends Rails patterns
5. **Document tool schemas** - JSON views should clearly define tool structure

## Next Steps for Documentation

When updating documentation:
1. Find hardcoded examples in markdown files
2. Create or update tests with proper regions
3. Add `doc_example_output` calls to generate examples
4. Replace hardcoded blocks with `<<<` imports
5. Add `@include` directives for example outputs
6. Run tests and verify documentation builds correctly