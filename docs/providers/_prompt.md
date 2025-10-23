# Provider Documentation Prompt

You are documenting a new ActiveAgent provider. Follow these guidelines to create comprehensive, accurate, and maintainable documentation.

## Critical Requirements

**Before writing any documentation:**

1. **Read the documentation guide** - Read the docs/contributing/documentation.md guideline
2. **Understand the provider** - Research the AI service's capabilities, models, and unique features
3. **Check implementation** - Examine the provider adapter in `lib/active_agent/providers/`
4. **Analyze existing provider documentation** - Review other provider docs to understand what's provider-specific vs. generic
5. **Plan documentation structure** - Identify what sections are needed, what can be removed, and what makes this provider unique
6. **Only after structure is finalized** - Review/refactor agent and test files to support the documentation

## Documentation Planning Phase

**Get the macro right before the micro.** Before touching any agent or test files:

### Step 1: Research the Provider

- What models does it offer?
- What unique parameters does it support?
- What special features differentiate it from other providers?
- What are its limitations or constraints?
- Review official provider documentation

### Step 2: Analyze What's Provider-Specific

Compare against the generic ActiveAgent framework to identify:

**Keep only provider-specific content:**
- ✅ Unique configuration options (API keys, base URLs, headers)
- ✅ Model identifiers and capabilities
- ✅ Provider-specific parameters (thinking mode, safety settings, etc.)
- ✅ Unique features (constitutional AI, local inference, routing, etc.)
- ✅ Provider-specific error classes
- ✅ Special authentication or setup requirements

**Remove generic content that applies to all providers:**
- ❌ How to create an agent (covered in agent docs)
- ❌ What prompts are (covered in framework docs)
- ❌ How tool calling works in general (covered in actions docs)
- ❌ General streaming concepts (covered in generation docs)
- ❌ Generic error handling patterns
- ❌ Basic Rails integration (covered in framework docs)

### Step 3: Create Documentation Outline

Based on your research, create a section-by-section outline:

```markdown
# [Provider Name]

## Sections to Include:
- [ ] Introduction (1-2 sentences on what makes this provider unique)
- [ ] Configuration (if setup differs from standard pattern)
- [ ] Supported Models (with official link + highlights)
- [ ] Provider-Specific Parameters (only unique params, organized by category)
- [ ] Provider-Specific Features (the most important section!)
- [ ] Error Handling (only if provider has unique error types)
- [ ] Related Documentation (standard links)

## Sections to Remove/Skip:
- [ ] Generic agent creation (not provider-specific)
- [ ] Generic prompt usage (not provider-specific)
- [ ] Generic tool calling (not provider-specific)
- [ ] ...

## Unique Selling Points:
1. [What makes this provider special?]
2. [What can it do that others can't?]
3. [Why would someone choose this provider?]
```

### Step 4: Validate Structure

Ask yourself:
- Does this documentation focus on provider-specific content?
- Would a developer already familiar with ActiveAgent find new, relevant information here?
- Are we duplicating content that exists in framework docs?
- Are we highlighting what makes this provider unique?

**Only after you have a clear, validated outline should you:**
- Review existing agent implementations
- Refactor test files to support documentation
- Add region markers
- Generate example outputs

## Documentation Structure

Your provider documentation should follow this structure:

### 1. Title and Introduction (1-2 sentences)

Start with a clear, concise description of what the provider enables. Mention key models and standout capabilities.

**Example:**
```markdown
# Anthropic Provider

The Anthropic provider enables integration with Claude models including Claude 3.5 Sonnet, Claude 3 Opus, and Claude 3 Haiku. It offers advanced reasoning capabilities, extended context windows, and strong performance on complex tasks.
```

### 2. Configuration Section

#### Basic Setup

Find or create the basic agent implementation in `test/dummy/app/agents/providers/`:

```markdown
### Basic Setup

Configure [Provider] in your agent:

<<< @/../test/dummy/app/agents/providers/provider_name_agent.rb#agent{ruby:line-numbers}
```

#### Basic Usage Example

Import a simple test example demonstrating basic generation:

```markdown
### Basic Usage Example

<<< @/../test/docs/providers/provider_provider_test.rb#provider_basic_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/provider-provider-test.rb-test-basic-generation-with-Provider.md -->
:::
```

#### Configuration File

Show YAML configuration using code groups to display both the anchor and actual config:

```markdown
### Configuration File

Set up [Provider] credentials in `config/active_agent.yml`:

::: code-group

<<< @/../test/dummy/config/active_agent.yml#provider_anchor{yaml:line-numbers}

<<< @/../test/dummy/config/active_agent.yml#provider_dev_config{yaml:line-numbers}

:::
```

#### Environment Variables

List relevant environment variables found in the providers options with clear examples:

```markdown
### Environment Variables

Alternatively, use environment variables:

\`\`\`bash
PROVIDER_API_KEY=your-api-key
PROVIDER_BASE_URL=https://api.provider.com  # Optional
\`\`\`
```

### 3. Supported Models

Document available models with brief descriptions, if available. Link to the provider's official documentation.

**Structure:**
- Link to official model list first
- Group models by family/capability
- Include model identifiers (strings used in code)
- Note context windows, capabilities, or costs if relevant

**Example:**
```markdown
## Supported Models

For the complete list of available models, see [Provider's Models Overview](https://provider.com/models).

### Model Family Name
- **model-identifier** - Description (context: 128k tokens)
- **other-model** - Description
```

### 4. Provider-Specific Parameters

Document all parameters supported by this provider's options and requests, organized by category.

**Categories to include:**
- Required Parameters
- Model/Generation Parameters (temperature, top_p, max_tokens, etc.)
- System & Instructions
- Tools & Functions (if supported)
- Streaming (if supported)
- Advanced/Unique Features
- Client Configuration (API keys, timeouts, base URLs)

**Format:**
```markdown
## Provider-Specific Parameters

### Required Parameters

- **`model`** - Model identifier (e.g., "model-name")
- **`param_name`** - Description (default: value, range: min-max)

### Sampling Parameters

- **`temperature`** - Controls randomness (0.0 to 1.0, default: 1.0)
- **`top_p`** - Nucleus sampling (0.0 to 1.0)

### Advanced Features

- **`unique_feature`** - Provider-specific capability
  \`\`\`ruby
  generate_with :provider,
    unique_feature: {
      option: -> { dynamic_value }
    }
  \`\`\`
```

### 5. Provider-Specific Features (Optional)

Highlight unique capabilities that differentiate this provider. This section is **critical** - focus on what makes the provider special.

**Examples of unique features:**
- Anthropic: Constitutional AI, thinking mode, extended context
- Ollama: Local inference, no API costs, privacy
- OpenAI: Function calling patterns, structured outputs
- OpenRouter: Multi-provider routing, fallback logic

**Show working examples:**
```markdown
## Provider-Specific Features

### Unique Feature Name

Brief explanation of the feature and why it matters.

<<< @/../test/docs/providers/provider_test.rb#unique_feature_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/provider-test.rb-test-unique-feature.md -->
:::
```

### 6. Error Handling

Demonstrate provider-specific error handling patterns:

```markdown
## Error Handling

Handle [Provider]-specific errors, if they exist. Note that some providers may inherit from other providers and thus use those error classes instead.

\`\`\`ruby
class ResilientAgent < ApplicationAgent
  generate_with :provider,
    model: "model-name",
    max_retries: 3

  rescue_from Provider::RateLimitError do |error|
    Rails.logger.warn "Rate limited: #{error.message}"
    sleep(error.retry_after || 60)
    retry
  end

  rescue_from Provider::APIError do |error|
    Rails.logger.error "Provider error: #{error.message}"
    fallback_to_cached_response
  end
end
\`\`\`
```

### 7. Related Documentation

Always include these links at the end:

```markdown
## Related Documentation

- [Providers Overview](/framework/providers)
- [Configuration Guide](/getting-started#configuration)
- [Provider API Documentation](https://provider.com/docs)
```

## VitePress Import Syntax

**Always use VitePress imports - never hardcode examples.**

### Import Full File

```markdown
<<< @/../test/dummy/app/agents/my_agent.rb{ruby:line-numbers}
```

### Import Region (Preferred for Tests)

```markdown
<<< @/../test/docs/my_agent_test.rb#example_name{ruby:line-numbers}
```

Region markers in test files:
```ruby
# region example_name
def test_something
  response = Agent.generate("test")
  doc_example_output(response)
  assert response.success?
end
# endregion example_name
```

### Import with Line Numbers

Always add `{ruby:line-numbers}` or `{yaml:line-numbers}` for code blocks.

### Include Generated Output

```markdown
::: details Response Example
<!-- @include: @/parts/examples/test-file-name.rb-test-method-name.md -->
:::
```

The file is auto-generated by `doc_example_output(response)` in the test.

### Code Groups (Multiple Files)

```markdown
::: code-group

<<< @/../test/dummy/app/agents/agent.rb{ruby:line-numbers}

<<< @/../test/dummy/app/views/agent/action.json.jbuilder{ruby:line-numbers}

:::
```

## Setting Up Code Regions

Regions mark the specific code you want to reference in documentation. They must be placed carefully to show only what's relevant.

### Agent Class Regions

For agent implementations, place regions **inside** the module namespace to hide module declarations:

```ruby
module Providers
  # Example agent using Anthropic's Claude models.
  #
  # Demonstrates basic prompt generation with the Anthropic provider.
  # Configured to use Claude Sonnet 4.5 with default instructions.
  #
  # @example Basic usage
  #   response = Providers::AnthropicAgent.ask(message: "Hello").generate_now
  #   response.message.content  #=> "Hi! How can I help you today?"
  # region agent
  class AnthropicAgent < ApplicationAgent
    generate_with :anthropic,
                  model: "claude-sonnet-4-5-20250929",
                  instructions: "You are a helpful AI assistant."

    # Generates a response to the provided message.
    #
    # @return [ActiveAgent::Generation]
    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
```

**Key points:**
- Region markers go **inside** the module, **around** the class
- Module namespace is excluded from documentation
- Keep comments and rdoc if they add value
- Use descriptive region name: `agent`, `full_implementation`, etc.

### Test Regions

For test examples, wrap **only the code you want to show** in documentation:

```ruby
# frozen_string_literal: true

require "test_helper"

module Providers
  class AnthropicProviderTest < ActiveSupport::TestCase
    test "basic generation with Anthropic Claude" do
      VCR.use_cassette("providers/anthropic_basic_generation") do
        # region anthropic_basic_example
        response = AnthropicAgent.with(
          message: "What is the Model Context Protocol?"
        ).ask.generate_now
        # endregion anthropic_basic_example

        doc_example_output(response)

        assert response.success?
        assert_not_nil response.message.content
        assert response.message.content.length > 0
      end
    end
  end
end
```

**Key points:**
- Region wraps **only the user-facing code**, not setup/assertions
- Exclude `VCR.use_cassette` from region
- Exclude `doc_example_output` and test assertions
- Place `doc_example_output` **outside** the region, **after** the code
- Use descriptive name matching the feature: `basic_example`, `streaming_example`, etc.

### Region Naming Conventions

- **`agent`** - Full agent class implementation
- **`{provider}_basic_example`** - Basic usage demonstration
- **`{feature}_example`** - Specific feature demonstration (e.g., `streaming_example`, `tool_calling_example`)
- **`{provider}_testing_example`** - Test setup pattern

Use `snake_case` and make names unique within each file.

## Workflow Checklist

When documenting a new provider, **follow this order**:

### Phase 1: Macro Planning (Do First)

- [ ] Research provider's official documentation and unique capabilities
- [ ] Examine provider implementation: `lib/active_agent/providers/{provider}.rb`
- [ ] Compare with other provider docs to understand patterns
- [ ] Create documentation outline (see "Documentation Planning Phase" above)
- [ ] Identify what sections are needed vs. what can be removed
- [ ] List provider's unique features and selling points
- [ ] Validate outline: Does it focus on provider-specific content?
- [ ] Get approval/feedback on structure before proceeding

### Phase 2: Micro Implementation (Do After Structure is Solid)

- [ ] Check existing test file: `test/integration/{provider}_test.rb`
- [ ] Check existing agent file: `test/dummy/app/agents/providers/{provider}_agent.rb`
- [ ] Refactor agent file if needed to support documentation examples
- [ ] Refactor test file if needed to demonstrate unique features
- [ ] Add region markers in agent file (around class, inside module)
- [ ] Add region markers in test file (around usage code only)
- [ ] Check for configuration: `test/dummy/config/active_agent.yml`
- [ ] Run tests to generate outputs: `bin/test test/integration/{provider}_test.rb`
- [ ] Verify example files generated in `docs/parts/examples/`

### Phase 3: Documentation Writing

- [ ] Create documentation file: `docs/providers/{provider}.md`
- [ ] Import all code using `<<<` syntax
- [ ] Include generated outputs using `@include`
- [ ] Preview locally: `bin/docs`
- [ ] Verify all imports render correctly
- [ ] Ensure each section focuses on provider-specific content
- [ ] Check that unique features are prominently highlighted
- [ ] Verify links and navigation work
- [ ] Review against quality checklist

## Common Patterns

### Basic Generation with Output

```markdown
<<< @/../test/docs/providers/provider_test.rb#basic_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/provider-test.rb-test-basic-example.md -->
:::
```

### Configuration Example

```markdown
::: code-group

<<< @/../test/dummy/config/active_agent.yml#provider_anchor{yaml:line-numbers}

<<< @/../test/dummy/config/active_agent.yml#provider_config{yaml:line-numbers}

:::
```

### Feature with Multiple Perspectives

```markdown
::: tabs

== Agent Implementation
<<< @/../test/dummy/app/agents/feature_agent.rb{ruby:line-numbers}

== Test Example
<<< @/../test/docs/feature_test.rb#example{ruby:line-numbers}

== Response
<!-- @include: @/parts/examples/feature-test.rb-test-example.md -->

:::
```

## What Makes Good Provider Documentation

**Focus on differences:**
- What models are available?
- What unique parameters does it support?
- What special features does it offer?
- How does configuration differ?
- What error types are specific to this provider?

**Don't repeat generic information:**
- Skip general ActiveAgent concepts (covered in framework docs)
- Don't explain how agents work (covered in agent docs)
- Focus on provider-specific configuration and features

**Use real, tested examples:**
- Every code snippet must come from a test file
- Every response must be generated by `doc_example_output`
- Never fabricate examples or outputs

**Keep it maintainable:**
- When code changes, docs auto-update via imports
- When tests change, outputs regenerate
- No manual synchronization needed

## Documentation Standards

From `docs/contributing/documentation.md`:

**Always:**
- ✅ Import all code with `<<<` syntax
- ✅ Test code before documenting
- ✅ Use regions for test examples
- ✅ Generate outputs with `doc_example_output`
- ✅ Add line numbers: `{ruby:line-numbers}`
- ✅ Preview locally before committing

**Never:**
- ❌ Hardcode examples in markdown
- ❌ Document untested features
- ❌ Copy/paste code from tests
- ❌ Break existing imports when refactoring

## Quality Checklist

Before considering provider documentation complete:

### Structure & Focus (Most Important)
- [ ] Documentation structure planned and validated before implementation
- [ ] Only provider-specific content included (no generic ActiveAgent concepts)
- [ ] Unique features section is comprehensive and prominent
- [ ] No duplication of content from framework/agent/action docs
- [ ] Each section answers "What makes this provider different?"

### Content Completeness
- [ ] Title clearly identifies the provider
- [ ] Introduction explains what it enables (1-2 sentences)
- [ ] Basic setup imports working agent example
- [ ] Basic usage shows tested generation example with output
- [ ] Configuration file uses code groups with YAML imports (if provider-specific setup exists)
- [ ] Environment variables listed with clear examples (if provider-specific)
- [ ] All supported models documented with official link
- [ ] All provider-specific parameters documented and categorized
- [ ] Error handling patterns shown (only if provider has unique error types)
- [ ] Related documentation links included

### Technical Quality
- [ ] All code uses VitePress `<<<` imports (no hardcoded examples)
- [ ] All outputs use `@include` from generated examples
- [ ] Documentation previews correctly with `bin/docs`
- [ ] All links work and navigate properly
- [ ] Region markers placed correctly (inside modules, around relevant code)

## Remember

**Get the macro right before the micro.** Plan the documentation structure and validate what's provider-specific before refactoring any code.

You're documenting **what makes this provider unique**. Developers can read the framework docs for general concepts. Your job is to show:

1. What makes this provider different from others
2. How to configure this specific provider (if different from standard)
3. What models and unique parameters it supports
4. What special features it offers (most important!)
5. Real, tested examples that demonstrate unique capabilities

**Focus on uniqueness:**
- If a feature works the same across all providers, it belongs in framework docs, not here
- If a parameter is standard across providers, don't document it here
- If configuration follows the standard pattern, keep it brief
- Highlight what sets this provider apart

**Process matters:**
1. **Research & Plan** - Understand the provider and create an outline
2. **Validate Structure** - Ensure focus on provider-specific content
3. **Implement** - Refactor agents/tests to support the validated structure
4. **Document** - Write docs using tested, imported examples

Every code example must be tested. Every output must be real. Documentation and code cannot drift apart.
