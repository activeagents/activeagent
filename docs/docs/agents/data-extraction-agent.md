---
title: Data Extraction Agent
---
# {{ $frontmatter.title }}
Active Agent is designed to allow developers to create agents with ease. This guide will help you set up a Data Extraction Agent that can extract structured data from unstructured text, images, or PDFs.

## Creating the Data Extraction Agent
To create a Data Extraction Agent, you can use the `rails generate active_agent:agent data_extraction parse_content` command. This will create a new agent class in `app/agents/data_extraction_agent.rb` and a corresponding view template in `app/views/data_extraction_agent/extract.text.erb`.

```bash
rails generate active_agent:agent data_extraction parse_content
```

::: code-group

<<< @/../test/dummy/app/agents/data_extraction_agent.rb {ruby}

<<< @/../test/dummy/app/views/data_extraction_agent/chart_schema.json.erb {json}

<<< @/../test/dummy/app/views/data_extraction_agent/resume_schema.json.erb {json}

:::

In the example above, we have two schemas: `chart_schema.json.erb` and `resume_schema.json.erb`. These schemas define the structure of the data that the agent will extract and can be passed into the agent's `parse_content` action using the `output_schema` parameter. This provides a flexible interface for the agent to extract data in various structured formats.

## Structured output
This Data Extraction Agent is designed to extract structured data from unstructured text, images, or PDFs. It uses a schema to define the structure of the output data. The schema is defined in a JSON file located in `app/views/data_extraction_agent/`. The agent will use this schema to instruct the generation provider to extract the data in the specified format.

### Example prompt with structured output schema

:::: code-group
<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart_with_structured_output {ruby:line-numbers}
::::

<!--@include: /parts/data-extraction-agent-example-prompt.md-->


### Example generation response

:::tabs
=== response [ruby]
```ruby [ruby]
<!-- @include: @/parts/examples/test-parse-chart-content-from-image-data-with-structured-output-schema-response.md{1,2} -->
```

::: details Full response output
```ruby
<!-- @include: @/parts/examples/test-parse-chart-content-from-image-data-with-structured-output-schema-response.md -->
```

=== tab 2
Hello World

:::

