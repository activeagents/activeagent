# OpenRouter Provider

OpenRouter provides access to multiple AI models through a unified API, with advanced features like fallback models, multimodal support, and PDF processing.

## Configuration

Configure OpenRouter in your agent:

<<< @/../test/dummy/app/agents/open_router_agent.rb#snippet{ruby:line-numbers}

## Features

### Structured Output Support

OpenRouter supports structured output for compatible models (like OpenAI's GPT-4o and GPT-4o-mini), allowing you to receive responses in a predefined JSON schema format. This is particularly useful for data extraction tasks.

#### Compatible Models

Models that support both vision capabilities AND structured output:
- `openai/gpt-4o`
- `openai/gpt-4o-mini`
- `openai/gpt-4-turbo` (structured output only, no vision)
- `openai/gpt-3.5-turbo` variants (structured output only, no vision)

#### Using Structured Output

Define your schema and pass it to the `prompt` method:

```ruby
class OpenRouterAgent < ApplicationAgent
  generate_with :open_router, model: "openai/gpt-4o-mini"
  
  def analyze_image
    @image_url = params[:image_url]
    
    prompt(
      message: build_image_message,
      output_schema: image_analysis_schema
    )
  end
  
  private
  
  def image_analysis_schema
    {
      name: "image_analysis",
      strict: true,
      schema: {
        type: "object",
        properties: {
          description: { type: "string" },
          objects: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
                position: { type: "string" },
                color: { type: "string" }
              },
              required: ["name", "position", "color"],
              additionalProperties: false
            }
          },
          scene_type: {
            type: "string",
            enum: ["indoor", "outdoor", "abstract", "document", "photo", "illustration"]
          }
        },
        required: ["description", "objects", "scene_type"],
        additionalProperties: false
      }
    }
  end
end
```

::: tip
When using `strict: true` with OpenAI models, all properties defined in your schema must be included in the `required` array. This ensures deterministic responses.
:::

For more comprehensive structured output examples, including receipt data extraction and document parsing, see the [Data Extraction Agent documentation](/docs/agents/data-extraction-agent#structured-output).

### Multimodal Support

OpenRouter supports vision-capable models for image analysis:

<<< @/../test/agents/open_router_integration_test.rb#36-62{ruby:line-numbers}

::: details Image Analysis with Structured Output
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-analyzes-remote-image-URL-without-structured-output.md -->
:::

### Receipt Data Extraction with Structured Output

Extract structured data from receipts and documents using OpenRouter's structured output capabilities. This example demonstrates how to parse receipt images and extract specific fields like merchant information, items, and totals.

#### Test Implementation

<<< @/../test/agents/open_router_integration_test.rb#89-145{ruby:line-numbers}

#### Receipt Schema Definition

<<< @/../test/dummy/app/agents/open_router_integration_agent.rb#188-234{ruby:line-numbers}

The receipt schema ensures consistent extraction of:
- Merchant name and address
- Individual line items with names and prices
- Subtotal, tax, and total amounts
- Currency information

::: details Receipt Extraction Example Output
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-extracts-receipt-data-with-structured-output-from-local-file.md -->
:::

::: tip
This example uses structured output to ensure the receipt data is returned in a consistent JSON format. For more examples of structured data extraction from various document types, see the [Data Extraction Agent documentation](/docs/agents/data-extraction-agent#structured-output).
:::

### PDF Processing

OpenRouter supports PDF processing with various engines:

<<< @/../test/agents/open_router_integration_test.rb#209-234{ruby:line-numbers}

::: details PDF Processing Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-processes-PDF-document-from-local-file.md -->
:::

#### PDF Processing Options

OpenRouter offers multiple PDF processing engines:

- **Native Engine**: Charged as input tokens, best for models with built-in PDF support
- **Mistral OCR Engine**: $2 per 1000 pages, optimized for scanned documents
- **No Plugin**: For models that have built-in PDF capabilities

Example with OCR engine:

<<< @/../test/agents/open_router_integration_test.rb#316-338{ruby:line-numbers}

::: details OCR Processing Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-processes-scanned-PDF-with-OCR-engine.md -->
:::

### Fallback Models

Configure fallback models for improved reliability:

<<< @/../test/agents/open_router_integration_test.rb#340-361{ruby:line-numbers}

::: details Fallback Model Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-uses-fallback-models-when-primary-fails.md -->
:::

### Content Transforms

Apply transforms for handling long content:

<<< @/../test/agents/open_router_integration_test.rb#363-380{ruby:line-numbers}

::: details Transform Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-applies-transforms-for-long-content.md -->
:::

### Usage and Cost Tracking

Track token usage and costs for OpenRouter requests:

<<< @/../test/agents/open_router_integration_test.rb#382-420{ruby:line-numbers}

::: details Usage Tracking Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-tracks-usage-and-costs.md -->
:::

## Provider Preferences

Configure provider preferences for routing and data collection:

<<< @/../test/agents/open_router_integration_test.rb#434-451{ruby:line-numbers}

## Headers and Site Configuration

OpenRouter supports custom headers for tracking and attribution:

<<< @/../test/agents/open_router_integration_test.rb#420-432{ruby:line-numbers}

## Model Capabilities Detection

The provider automatically detects model capabilities:

<<< @/../test/agents/open_router_integration_test.rb#16-33{ruby:line-numbers}

## Important Notes

### Model Compatibility

When using OpenRouter's advanced features, ensure your chosen model supports the required capabilities:

- **Structured Output**: Requires models like `openai/gpt-4o`, `openai/gpt-4o-mini`, or other OpenAI models with structured output support
- **Vision/Image Analysis**: Requires vision-capable models like GPT-4o, Claude 3, or Gemini Pro Vision
- **PDF Processing**: May require specific plugins or engines depending on the model and document type

For tasks requiring both vision and structured output (like receipt extraction), use models that support both capabilities, such as:
- `openai/gpt-4o`
- `openai/gpt-4o-mini`

## See Also

- [Data Extraction Agent](/docs/agents/data-extraction-agent) - Comprehensive examples of structured data extraction
- [Generation Provider Overview](/docs/framework/generation-provider) - Understanding provider architecture
- [OpenRouter API Documentation](https://openrouter.ai/docs) - Official OpenRouter documentation