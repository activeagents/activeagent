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
<!-- @include: @/parts/examples/test-describe-cat-image-creates-a-multimodal-prompt-with-image-and-text-content-test-describe-cat-image-creates-a-multimodal-prompt-with-image-and-text-content.md -->
:::

### Image: Parse Chart Data

Active Agent can extract data from chart images:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart {ruby:line-numbers}

::: details Basic Chart Image Response Example
<!-- @include: @/parts/examples/test-parse-chart-content-from-image-data-test-parse-chart-content-from-image-data.md -->
:::

## Structured Output
Active Agent supports structured output using JSON schemas. Define schemas in your agent's views directory (e.g., `app/views/data_extraction_agent/`) and reference them using the `output_schema` parameter.

### Structured Output Schemas

When using structured output:
- The response will have `content_type` of `application/json`
- The response content will be valid JSON matching your schema
- Parse the response with `JSON.parse(response.message.content)`


### Parse Chart Image with Structured Output
![Chart Image](https://raw.githubusercontent.com/activeagents/activeagent/main/test/dummy/test/fixtures/images/sales_chart.png)

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
<!-- @include: @/parts/examples/test-parse-chart-content-from-image-data-with-structured-output-schema-test-parse-chart-content-from-image-data-with-structured-output-schema.md -->
:::
== JSON Output

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart_with_structured_output_json {ruby}
::: details Parse Chart JSON Response Example
<!-- @include: @/parts/examples/test-parse-chart-content-from-image-data-with-structured-output-schema-parse-chart-json-response.md -->
:::
::::

### Parse Resume

Extract information from PDF resumes:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_resume {ruby:line-numbers}

### Parse Resume with Structured Output
![Resume PDF](https://raw.githubusercontent.com/activeagents/activeagent/main/test/dummy/test/fixtures/files/sample_resume.pdf)
Extract resume data with a predefined schema:

:::: tabs

== Prompt Generation

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_resume_with_structured_output_response {ruby:line-numbers}
<!-- @include: @/parts/examples/test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema-test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema.md -->

== JSON Output

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_resume_with_structured_output_json {ruby:line-numbers}
<!-- @include: @/parts/examples/test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema-parse-resume-json-response.md -->

:::
::::