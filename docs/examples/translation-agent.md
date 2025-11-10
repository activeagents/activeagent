---
title: Translation Agent
description: Create specialized agents for language translation tasks. Demonstrates how to build focused, single-purpose agents with clear responsibilities.
---
# {{ $frontmatter.title }}

The Translation Agent demonstrates how to create specialized agents for specific tasks like language translation.

## Setup

Generate a translation agent:

```bash
rails generate active_agent:agent translation translate
```

## Implementation

```ruby
class TranslationAgent < ApplicationAgent
  generate_with :openai, instructions: "Translate the given text from one language to another."

  def translate
    prompt
  end
end
```

## Usage Examples

### Basic Translation

The translation agent accepts a message and target locale:

```ruby
translate_prompt = TranslationAgent.with(
  message: "Hi, I'm Justin",
  locale: "japanese"
).translate

puts translate_prompt.message.content
# => "translate: Hi, I'm Justin; to japanese"

puts translate_prompt.instructions
# => "Translate the given text from one language to another."
```

### Translation Generation

Generate a translation using the configured AI provider:

```ruby
response = TranslationAgent.with(
  message: "Hi, I'm Justin",
  locale: "japanese"
).translate.generate_now

puts response.message.content
# => "こんにちは、私はジャスティンです。"
```

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

```erb
translate: <%= params[:message] %>; to <%= params[:locale] %>
```
