---
title: Data Extraction
description: Extract structured data from PDF resumes using AI-powered parsing. Demonstrates multimodal input and structured output with JSON schemas.
---
# {{ $frontmatter.title }}

Extract structured data from PDF resumes using AI-powered parsing.

## Setup

```bash
rails generate active_agent:agent resume_extractor parse --json-schema
```

This creates:
- `app/agents/resume_extractor_agent.rb` - Agent class
- `app/views/agents/resume_extractor/instructions.md` - Instructions
- `app/views/agents/resume_extractor/parse.json` - JSON schema

## Quick Start

Download this sample resume to test the agent: [Sample Resume](https://docs.activeagents.ai/sample_resume.pdf)

<<< @/../test/docs/examples/data_extraction_agent_examples_test.rb#quick_start_usage{ruby:line-numbers}

::: details JSON Message
<!-- @include: @/parts/examples/data-extraction-agent-examples-test.rb-test-quick-start-extraction.md -->
:::

## How It Works

The agent uses structured output to guarantee JSON matching your schema:

::: code-group
<<< @/../test/docs/examples/data_extraction_agent_examples_test.rb#quick_start_agent{ruby:line-numbers} [resume_extractor_agent.rb]

<<< @/../test/dummy/app/views/agents/docs/examples/data_extraction_agent_examples/quick_start/resume_extractor/parse.json {json:line-numbers} [parse.json]

:::

**Key features:**
- `strict: true` - Enforces exact schema compliance
- `additionalProperties: false` - Rejects unexpected fields
- Automatic JSON parsing - `response.message.content` returns a hash
- Type validation - Ensures correct data types (string, integer, array)

## Schema Options

### Static Schema Files

Define schemas in JSON files under `app/views/agents/resume_extractor/`:

```ruby
  response_format: :json_schema  # Loads parse.json automatically
```

**When to use:**
- Standard data structures
- Stable requirements
- Team collaboration (reviewable JSON files)

### Model-Generated Schemas

Generate schemas dynamically from your models:

::: code-group

<<< @/../test/docs/examples/data_extraction_agent_examples_test.rb#model_generated_schema_model {ruby:line-numbers} [resume.rb]

<<< @/../test/docs/examples/data_extraction_agent_examples_test.rb#model_generated_schema_agent {ruby:line-numbers} [resume_extractor_agent.rb]

:::

**When to use:**
- Existing ActiveRecord/ActiveModel classes
- Schema mirrors database structure
- Single source of truth for validations

Learn more: [Structured Output](/actions/structured-output#schema-generation)

## Common Patterns

### Background Processing

For high-volume processing:

```ruby
class ResumeProcessingJob < ApplicationJob
  def perform(pdf_path)
    pdf_data = File.read(pdf_path)
    pdf_url = "data:application/pdf;base64,#{Base64.strict_encode64(pdf_data)}"

    response = ResumeExtractorAgent.with(document: pdf_url).parse.generate_now

    Resume.create!(response.message.content) if response.success?
  end
end

# Enqueue jobs
Dir.glob("resumes/*.pdf").each do |path|
  ResumeProcessingJob.perform_later(path)
end
```

### Consensus Validation

Ensure extraction accuracy by requiring multiple attempts to agree:

<<< @/../test/docs/examples/data_extraction_agent_examples_test.rb#consensus_validation_example {ruby:line-numbers} [resume_extractor_agent.rb]

This validates extraction reliability by running the agent twice and comparing results. Useful for:
- Critical data where accuracy is essential
- Detecting inconsistent model outputs
- Building confidence in extracted data

## Provider Support

Resume extraction works with providers that support:
- **PDF processing** - Native or via plugins
- **Structured output** - JSON schema validation

### Recommended Providers

| Provider | Model | Notes |
|:---------|:------|:------|
| **OpenAI** | gpt-4o | Native PDF support, structured output |
| **OpenAI** | gpt-4o-mini | Faster, lower cost |
| **Anthropic** | claude-3-5-sonnet | Strong reasoning, base64 PDF |
| **OpenRouter** | openai/gpt-4o | Access via OpenRouter |

::: tip
OpenAI's GPT-4o models provide the best balance of accuracy and speed for resume extraction with native structured output support.
:::

## See Also

- [Structured Output](/actions/structured-output) - JSON schema validation
- [Messages](/actions/messages) - Multimodal content (PDFs, images)
- [OpenAI Provider](/providers/open-ai) - Configuration details
- [OpenRouter Provider](/providers/open-router) - Alternative provider with 200+ models
