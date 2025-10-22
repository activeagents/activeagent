---
title: Translation Agent
---
# {{ $frontmatter.title }}

The Translation Agent demonstrates how to create specialized agents for specific tasks like language translation.

## Setup

Generate a translation agent:

```bash
rails generate active_agent:agent translation translate
```

## Implementation

<<< @/../test/dummy/app/agents/translation_agent.rb {ruby}

## Usage Examples

### Basic Translation

The translation agent accepts a message and target locale:

<<< @/../test/agents/translation_agent_test.rb#translation_agent_render_translate_prompt {ruby:line-numbers}

### Translation Generation

Generate a translation using the configured AI provider:

<<< @/../test/agents/translation_agent_test.rb#translation_agent_translate_prompt_generation {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/translation-agent-test.rb-test-it-renders-a-translate-prompt-and-generates-a-translation.md -->
:::

## Key Features

- **Action-based Translation**: Use the `translate` action to process translations
- **Locale Support**: Pass target language as a parameter
- **Prompt Templates**: Customize translation prompts through view templates
- **Instruction Override**: Define custom translation instructions per agent

## View Templates

The translation agent uses view templates to format prompts:

<<< @/../test/dummy/app/views/translation_agent/translate.text.erb {erb}