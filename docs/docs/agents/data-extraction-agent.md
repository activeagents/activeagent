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

## Examples

### Image Description

Extract descriptions from images without structured output:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_describe_cat_image {ruby:line-numbers}

#### Response

<!-- @include: @/parts/examples/test-describe-cat-image-creates-a-multimodal-prompt-with-image-and-text-content-test-describe-cat-image-creates-a-multimodal-prompt-with-image-and-text-content.md -->

### Parse Chart Data

Extract data from chart images:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart {ruby:line-numbers}

#### Response

<!-- @include: @/parts/examples/test-parse-chart-content-from-image-data-test-parse-chart-content-from-image-data.md -->

### Parse Chart with Structured Output

Extract chart data with a predefined schema:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart_with_structured_output {ruby:line-numbers}

#### Response

::: tabs

== Response Object

<!-- @include: @/parts/examples/test-parse-chart-content-from-image-data-with-structured-output-schema-test-parse-chart-content-from-image-data-with-structured-output-schema.md -->

== JSON Output

<!-- @include: @/parts/examples/test-parse-chart-content-from-image-data-with-structured-output-schema-parse-chart-json-response.md -->

:::

### Parse Resume

Extract information from PDF resumes:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_resume {ruby:line-numbers}

#### Response

<!-- @include: @/parts/examples/test-parse-resume-creates-a-multimodal-prompt-with-file-data-test-parse-resume-creates-a-multimodal-prompt-with-file-data.md -->

### Parse Resume with Structured Output

Extract resume data with a predefined schema:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_resume_with_structured_output {ruby:line-numbers}

#### Response

::: tabs

== Response Object

<!-- @include: @/parts/examples/test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema-test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema.md -->

== JSON Output

<!-- @include: @/parts/examples/test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema-parse-resume-json-response.md -->

:::

## Structured Output

The Data Extraction Agent supports structured output using JSON schemas. Define schemas in your agent's views directory (e.g., `app/views/data_extraction_agent/`) and reference them using the `output_schema` parameter.

When using structured output:
- The response will have `content_type` of `application/json`
- The response content will be valid JSON matching your schema
- Parse the response with `JSON.parse(response.message.content)`