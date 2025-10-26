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

```ruby [data_extraction_agent.rb]
class DataExtractionAgent < ApplicationAgent
  before_action :set_multimodal_content, only: [:parse_content]

  def parse_content
    prompt_args = {
      message: params[:message] || "Parse the content of the file or image",
      image_data: @image_data,
      file_data: @file_data
    }

    if params[:response_format]
      prompt_args[:response_format] = params[:response_format]
    elsif params[:output_schema]
      # Support legacy output_schema parameter
      prompt_args[:response_format] = {
        type: "json_schema",
        json_schema: params[:output_schema]
      }
    end

    prompt(**prompt_args)
  end

  def describe_cat_image
    prompt(
      message: "Describe the cat in the image",
      image_data: CatImageService.fetch_base64_image
    )
  end

  private

  def set_multimodal_content
    if params[:file_path].present?
      @file_data ||= "data:application/pdf;base64,#{Base64.encode64(File.read(params[:file_path]))}"
    elsif params[:image_path].present?
      @image_data ||= "data:image/jpeg;base64,#{Base64.encode64(File.read(params[:image_path]))}"
    end
  end
end
```

```json [chart_schema.json.erb]
{
  "format": {
    "type": "json_schema",
    "name": "chart_schema",
    "schema": {
      "type": "object",
      "properties": {
        "title": {
          "type": "string",
          "description": "The title of the chart."
        },
        "data_points": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/data_point"
          }
        }
      },
      "required": ["title", "data_points"],
      "additionalProperties": false,
      "$defs": {
        "data_point": {
          "type": "object",
          "properties": {
            "label": {
              "type": "string",
              "description": "The label for the data point."
            },
            "value": {
              "type": "number",
              "description": "The value of the data point."
            }
          },
          "required": ["label", "value"],
          "additionalProperties": false
        }
      }
    }
  }
}
```

```json [resume_schema.json.erb]
{
  "format": {
    "type": "json_schema",
    "name": "resume_schema",
    "schema": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "The full name of the individual."
        },
        "email": {
          "type": "string",
          "format": "email",
          "description": "The email address of the individual."
        },
        "phone": {
          "type": "string",
          "description": "The phone number of the individual."
        },
        "education": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/education"
          }
        },
        "experience": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/experience"
          }
        }
      },
      "required": ["name", "email", "phone", "education", "experience"],
      "additionalProperties": false,
      "$defs": {
        "education": {
          "type": "object",
          "properties": {
            "degree": {
              "type": "string",
              "description": "The degree obtained."
            },
            "institution": {
              "type": "string",
              "description": "The institution where the degree was obtained."
            },
            "year": {
              "type": "integer",
              "description": "The year of graduation."
            }
          },
          "required": ["degree", "institution", "year"],
          "additionalProperties": false
        },
        "experience": {
          "type": "object",
          "properties": {
            "job_title": {
              "type": "string",
              "description": "The job title held."
            },
            "company": {
              "type": "string",
              "description": "The company where the individual worked."
            },
            "duration": {
              "type": "string",
              "description": "The duration of employment."
            }
          },
          "required": ["job_title", "company", "duration"],
          "additionalProperties": false
        }
      }
    },
    "strict": true
  }
}
```

:::

## Basic Image Example

### Image Description

Active Agent can extract descriptions from images without structured output:

```ruby
prompt = DataExtractionAgent.describe_cat_image
response = prompt.generate_now

# The response contains a natural language description
puts response.message.content
# => "The cat in the image appears to have a primarily dark gray coat..."
```

::: details Basic Cat Image Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-describe-cat-image-creates-a-multimodal-prompt-with-image-and-text-content.md -->
:::

### Image: Parse Chart Data

Active Agent can extract data from chart images:

```ruby
sales_chart_path = Rails.root.join("test", "fixtures", "images", "sales_chart.png")

prompt = DataExtractionAgent.with(
  image_path: sales_chart_path
).parse_content

response = prompt.generate_now

# The response contains chart analysis
puts response.message.content
# => "The image is a bar chart titled 'Quarterly Sales Report'..."
```

::: details Basic Chart Image Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-parse-chart-content-from-image-data.md -->
:::

## Structured Output
Active Agent supports structured output using JSON schemas. Define schemas in your agent's views directory (e.g., `app/views/agents/data_extraction/`) and reference them using `response_format: { type: "json_schema", json_schema: :schema_name }`. [Learn more about structured output →](/actions/structured-output)

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
Structured output requires a provider that supports JSON schemas. Currently supported providers include:
- **OpenAI** - GPT-4o, GPT-4o-mini, GPT-3.5-turbo variants
- **OpenRouter** - When using compatible models like OpenAI models through OpenRouter

See the [OpenRouter Provider documentation](/providers/open-router-provider#structured-output-support) for details on using structured output with multiple model providers.
:::


### Parse Chart Image with Structured Output
![Chart Image](https://raw.githubusercontent.com/activeagents/activeagent/refs/heads/main/test/fixtures/images/sales_chart.png)

Extract chart data with a predefined schema `chart_schema`:

```ruby
sales_chart_path = Rails.root.join("test", "fixtures", "images", "sales_chart.png")

prompt = DataExtractionAgent.with(
  response_format: {
    type: "json_schema",
    json_schema: :chart_schema
  },
  image_path: sales_chart_path
).parse_content

response = prompt.generate_now

# When using json_schema response_format, content is already parsed
json_response = response.message.content

puts json_response["title"]
# => "Quarterly Sales Report"
puts json_response["data_points"].first
# => {"label"=>"Q1", "value"=>25000}
```

#### Response

:::: tabs

== Response Object
```ruby
response = prompt.generate_now
# Response has parsed JSON content
```
::: details Generation Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-parse-chart-content-from-image-data-with-structured-output-schema.md -->
:::
== JSON Output

```ruby
# When using json_schema response_format, content is already parsed
json_response = response.message.content
```
::: details Parse Chart JSON Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-parse-chart-json-response.md -->
:::
::::

### Parse Resume with output resume schema

Extract information from PDF resumes:

```ruby
sample_resume_path = Rails.root.join("test", "fixtures", "files", "sample_resume.pdf")

prompt = DataExtractionAgent.with(
  file_path: sample_resume_path
).parse_content

response = prompt.generate_now

# When using json_schema response_format, content is auto-parsed
puts response.message.content["name"]
# => "John Doe"
puts response.message.content["experience"].first["job_title"]
# => "Senior Software Engineer"
```

#### Parse Resume with Structured Output
[![Sample Resume](/sample_resume.png)](https://docs.activeagents.ai/sample_resume.pdf)
Extract resume data with a predefined `resume_schema`:

:::: tabs

== Prompt Generation

```ruby
prompt = DataExtractionAgent.with(
  file_path: Rails.root.join("test", "fixtures", "files", "sample_resume.pdf")
).parse_content

response = prompt.generate_now
```
::: details Generation Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema.md -->
:::
== JSON Output

```ruby
# When using json_schema response_format, content is already parsed
json_response = response.message.content

puts json_response["name"]
# => "John Doe"
puts json_response["email"]
# => "john.doe@example.com"
```
::: details Parse Resume JSON Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-parse-resume-json-response.md -->
:::
::::

## Advanced Examples

### Receipt Data Extraction with OpenRouter

For extracting data from receipts and invoices, you can use OpenRouter's multimodal capabilities combined with structured output. OpenRouter provides access to models that support both vision and structured output, making it ideal for document processing tasks.

See the [OpenRouter Receipt Extraction example](/providers/open-router-provider#receipt-data-extraction-with-structured-output) for a complete implementation that extracts:
- Merchant information (name, address)
- Line items with prices
- Tax and total amounts
- Currency details

### Using Different Providers

The Data Extraction Agent can work with any provider that supports the required capabilities:

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

Learn more about configuring providers in the [Providers Overview](/framework/providers).
:::
