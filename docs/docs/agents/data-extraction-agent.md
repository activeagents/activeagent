---
title: Data Extraction Agent
---
# {{ $frontmatter.title }}

Active Agent provides data extraction capabilities to parse structured data from unstructured text, images, or PDFs.

## Setup

Generate a data extraction agent:

```bash
rails generate active_agent:agent data_extraction parse_content
```

## Agent Implementation

::: code-group

<<< @/../test/dummy/app/agents/data_extraction_agent.rb {ruby}

<<< @/../test/dummy/app/views/data_extraction_agent/chart_schema.json.erb {json}

<<< @/../test/dummy/app/views/data_extraction_agent/resume_schema.json.erb {json}

:::

## Basic Image Example

### Image Description

Active Agent can extract descriptions from images without structured output:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_describe_cat_image {ruby:line-numbers}

::: details Basic Cat Image Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-describe-cat-image-creates-a-multimodal-prompt-with-image-and-text-content.md -->
:::

### Image: Parse Chart Data

Active Agent can extract data from chart images:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart {ruby:line-numbers}

::: details Basic Chart Image Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-parse-chart-content-from-image-data.md -->
:::

## Structured Output
Active Agent supports structured output using JSON schemas. Define schemas in your agent's views directory (e.g., `app/views/data_extraction_agent/`) and reference them using the `output_schema` parameter. [Learn more about prompt structure and schemas →](/docs/action-prompt/prompts)

### Structured Output Schemas

When using structured output:
- The response will have `content_type` of `application/json`
- The response content will be valid JSON matching your schema
- Parse the response with `JSON.parse(response.message.content)`

#### Generating Schemas from Models

ActiveAgent provides a `SchemaGenerator` module that can automatically create JSON schemas from your ActiveRecord and ActiveModel classes. This makes it easy to ensure extracted data matches your application's data models.

##### Basic Usage

::: code-group
<<< @/../test/schema_generator_test.rb#basic_user_model {ruby:line-numbers}
<<< @/../test/schema_generator_test.rb#basic_schema_generation {ruby:line-numbers}
:::

The `to_json_schema` method generates a JSON schema from your model's attributes and validations.

##### Schema with Validations

Model validations are automatically included in the generated schema:

<<< @/../test/schema_generator_test.rb#schema_with_validations {ruby:line-numbers}

##### Strict Schema for Structured Output

For use with AI providers that support structured output, generate a strict schema:

::: code-group
<<< @/../test/schema_generator_test.rb#blog_post_model {ruby:line-numbers}
<<< @/../test/schema_generator_test.rb#strict_schema_generation {ruby:line-numbers}
:::

##### Using Generated Schemas in Agents

Agents can use the schema generator to create structured output schemas dynamically:

<<< @/../test/schema_generator_test.rb#agent_using_schema {ruby:line-numbers}

This allows you to maintain a single source of truth for your data models and automatically generate schemas for AI extraction.

::: info Provider Support
Structured output requires a generation provider that supports JSON schemas. Currently supported providers include:
- **OpenAI** - GPT-4o, GPT-4o-mini, GPT-3.5-turbo variants
- **OpenRouter** - When using compatible models like OpenAI models through OpenRouter

See the [OpenRouter Provider documentation](/docs/generation-providers/open-router-provider#structured-output-support) for details on using structured output with multiple model providers.
:::


### Parse Chart Image with Structured Output
![Chart Image](https://raw.githubusercontent.com/activeagents/activeagent/refs/heads/main/test/fixtures/images/sales_chart.png)

Extract chart data with a predefined schema `chart_schema`:
::: code-group
<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart_with_structured_output {ruby:line-numbers}

<<< @/../test/dummy/app/views/data_extraction_agent/chart_schema.json.erb {json}
:::

#### Response

:::: tabs

== Response Object
<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart_with_structured_output_response {ruby}
::: details Generation Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-parse-chart-content-from-image-data-with-structured-output-schema.md -->
:::
== JSON Output

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart_with_structured_output_json {ruby}
::: details Parse Chart JSON Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-parse-chart-json-response.md -->
:::
::::

### Parse Resume with output resume schema

Extract information from PDF resumes:

::: code-group
<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_resume {ruby:line-numbers}
<<< @/../test/dummy/app/views/data_extraction_agent/resume_schema.json.erb {json}
:::

#### Parse Resume with Structured Output
[![Sample Resume](/sample_resume.png)](https://docs.activeagents.ai/sample_resume.pdf)
Extract resume data with a predefined `resume_schema`:

:::: tabs

== Prompt Generation

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_resume_with_structured_output_response {ruby:line-numbers}
::: details Generation Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema.md -->
:::
== JSON Output

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_resume_with_structured_output_json {ruby:line-numbers}
::: details Parse Resume JSON Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-parse-resume-json-response.md -->
:::
::::

## Advanced Examples

### Receipt Data Extraction with OpenRouter

For extracting data from receipts and invoices, you can use OpenRouter's multimodal capabilities combined with structured output. OpenRouter provides access to models that support both vision and structured output, making it ideal for document processing tasks.

See the [OpenRouter Receipt Extraction example](/docs/generation-providers/open-router-provider#receipt-data-extraction-with-structured-output) for a complete implementation that extracts:
- Merchant information (name, address)
- Line items with prices
- Tax and total amounts
- Currency details

### Using Different Providers

The Data Extraction Agent can work with any generation provider that supports the required capabilities:

- **For text extraction**: Any provider (OpenAI, Anthropic, Ollama, etc.)
- **For image analysis**: Providers with vision models (OpenAI GPT-4o, Anthropic Claude 3, etc.)
- **For structured output**: OpenAI models or OpenRouter with compatible models
- **For PDF processing**: OpenRouter with PDF plugins or models with native PDF support

::: tip Provider Selection
Choose your provider based on your specific needs:
- **OpenAI**: Best for structured output with GPT-4o/GPT-4o-mini
- **OpenRouter**: Access to 200+ models with fallback support
- **Anthropic**: Strong reasoning capabilities with Claude models
- **Ollama**: Local model deployment for privacy-sensitive data

Learn more about configuring providers in the [Generation Provider Overview](/docs/framework/generation-provider).
:::