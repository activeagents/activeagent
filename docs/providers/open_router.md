# OpenRouter Provider

OpenRouter provides access to multiple AI models through a unified API, with advanced features like fallback models, multimodal support, and PDF processing.

## Configuration

### Basic Setup

Configure OpenRouter in your agent:

<<< @/../test/dummy/app/agents/providers/open_router_agent.rb#agent{ruby:line-numbers}

### Basic Usage Example

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_basic_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/open-router-provider-test.rb-test-basic-generation-with-OpenRouter.md -->
:::

### Configuration File

Set up OpenRouter credentials in `config/active_agent.yml`:

::: code-group

<<< @/../test/dummy/config/active_agent.yml#open_router_anchor{yaml:line-numbers}

<<< @/../test/dummy/config/active_agent.yml#open_router_dev_config{yaml:line-numbers}

:::

### Environment Variables

Alternatively, use environment variables:

```bash
OPEN_ROUTER_API_KEY=your-api-key
# or
OPEN_ROUTER_ACCESS_TOKEN=your-api-key
```

## Supported Models

OpenRouter provides access to models from multiple providers:

### OpenAI Models
- **openai/gpt-4o** - Most capable with vision and structured output
- **openai/gpt-4o-mini** - Efficient with vision and structured output
- **openai/gpt-4-turbo** - Advanced reasoning with structured output
- **openai/o1** - Latest reasoning model

### Anthropic Models
- **anthropic/claude-3-5-sonnet** - Balanced performance
- **anthropic/claude-3-opus** - Most capable Claude model
- **anthropic/claude-3-haiku** - Fast and efficient

### Google Models
- **google/gemini-pro-1.5** - Latest Gemini with long context
- **google/gemini-flash-1.5** - Fast and efficient

### Meta Models
- **meta-llama/llama-3.1-405b** - Largest Llama model
- **meta-llama/llama-3.1-70b** - Balanced performance

### Other Providers
- **qwen/qwen3-30b-a3b:free** - Free tier model
- **mistralai/mistral-large** - Mistral's largest model
- **deepseek/deepseek-chat** - DeepSeek's chat model

For a complete list of available models, visit [OpenRouter Models](https://openrouter.ai/models).

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

For more comprehensive structured output examples, including receipt data extraction and document parsing, see the [Data Extraction Agent documentation](/examples/data-extraction-agent#structured-output).

### Multimodal Support

OpenRouter supports vision-capable models for image analysis:

```ruby
require "test_helper"

class OpenRouterMultimodalTest < ActiveSupport::TestCase
  test "analyzes image with structured output" do
    VCR.use_cassette("openrouter_image_analysis") do
      response = OpenRouterIntegrationAgent.analyze_image(
        image_url: "https://example.com/test-image.jpg"
      ).generate_now

      assert_not_nil response
      result = response.parsed_content

      assert_not_nil result["description"]
      assert_instance_of Array, result["objects"]
      assert_includes ["indoor", "outdoor", "abstract", "document", "photo", "illustration"],
                      result["scene_type"]
      assert_instance_of Array, result["primary_colors"]
    end
  end
end
```

For the complete agent implementation with image analysis schemas, see `test/dummy/app/agents/open_router_integration_agent.rb`.

::: details Image Analysis with Structured Output
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-analyzes-remote-image-URL-without-structured-output.md -->
:::

### Receipt Data Extraction with Structured Output

Extract structured data from receipts and documents using OpenRouter's structured output capabilities. This example demonstrates how to parse receipt images and extract specific fields like merchant information, items, and totals.

#### Test Implementation

```ruby
test "extracts receipt data with structured output" do
  VCR.use_cassette("openrouter_receipt_extraction") do
    response = OpenRouterIntegrationAgent.extract_receipt_data(
      image_path: "test/fixtures/files/sample_receipt.png"
    ).generate_now

    result = response.parsed_content

    # Verify merchant information
    assert_not_nil result["merchant"]
    assert_not_nil result["merchant"]["name"]
    assert_not_nil result["merchant"]["address"]

    # Verify totals
    assert_not_nil result["total"]
    assert_instance_of Numeric, result["total"]["amount"]

    # Verify items
    assert_instance_of Array, result["items"]
    assert result["items"].length > 0
  end
end
```

#### Receipt Schema Definition

<<< @/../test/dummy/app/agents/open_router_integration_agent.rb#receipt_schema{ruby:line-numbers}

The receipt schema ensures consistent extraction of:
- Merchant name and address
- Individual line items with names and prices
- Subtotal, tax, and total amounts
- Currency information

::: details Receipt Extraction Example Output
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-extracts-receipt-data-with-structured-output-from-local-file.md -->
:::

::: tip
This example uses structured output to ensure the receipt data is returned in a consistent JSON format. For more examples of structured data extraction from various document types, see the [Data Extraction Agent documentation](/examples/data-extraction-agent#structured-output).
:::

### PDF Processing

OpenRouter supports PDF processing with various engines:

```ruby
test "processes PDF document from local file" do
  VCR.use_cassette("openrouter_pdf_processing") do
    pdf_data = Base64.strict_encode64(File.read("test/fixtures/files/sample.pdf"))

    response = OpenRouterIntegrationAgent.analyze_pdf(
      pdf_data: pdf_data,
      pdf_engine: "pdf-text",
      prompt_text: "Summarize this PDF document"
    ).generate_now

    assert_not_nil response
    assert_not_nil response.message.content
  end
end
```

::: details PDF Processing Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-processes-PDF-document-from-local-file.md -->
:::

#### PDF Processing Options

OpenRouter offers multiple PDF processing engines:

- **Native Engine**: Charged as input tokens, best for models with built-in PDF support
- **Mistral OCR Engine**: $2 per 1000 pages, optimized for scanned documents
- **No Plugin**: For models that have built-in PDF capabilities

Example with OCR engine:

```ruby
test "processes scanned PDF with OCR engine" do
  VCR.use_cassette("openrouter_pdf_ocr") do
    response = OpenRouterIntegrationAgent.analyze_pdf(
      pdf_url: "https://example.com/scanned-receipt.pdf",
      pdf_engine: "mistral-ocr",
      prompt_text: "Extract all text from this scanned document"
    ).generate_now

    assert_not_nil response
    assert response.message.content.length > 0
  end
end
```

::: details OCR Processing Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-processes-scanned-PDF-with-OCR-engine.md -->
:::

### Fallback Models

Configure fallback models for improved reliability:

```ruby
class RobustAgent < ApplicationAgent
  generate_with :open_router,
    model: "openai/gpt-4o",
    fallback_models: ["anthropic/claude-sonnet-4", "openai/gpt-4o-mini"],
    enable_fallbacks: true

  def analyze
    prompt(message: params[:message])
  end
end

# Test fallback behavior
test "uses fallback models when primary fails" do
  VCR.use_cassette("openrouter_fallback") do
    response = RobustAgent.analyze(
      message: "Explain quantum computing"
    ).generate_now

    assert_not_nil response
    # Fallback models are automatically tried if primary fails
  end
end
```

::: details Fallback Model Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-uses-fallback-models-when-primary-fails.md -->
:::

### Content Transforms

Apply transforms for handling long content:

```ruby
test "applies transforms for long content" do
  VCR.use_cassette("openrouter_transforms") do
    long_text = "Lorem ipsum " * 1000

    response = OpenRouterIntegrationAgent.process_long_text(
      text: long_text
    ).generate_now

    assert_not_nil response
    # middle-out transform helps with long context
  end
end
```

For more details on content transforms, see the [OpenRouter transforms documentation](https://openrouter.ai/docs/transforms).

::: details Transform Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-applies-transforms-for-long-content.md -->
:::

### Usage and Cost Tracking

Track token usage and costs for OpenRouter requests:

```ruby
test "tracks usage and costs" do
  VCR.use_cassette("openrouter_usage_tracking") do
    response = OpenRouterIntegrationAgent.analyze_content(
      content: "What is the capital of France?"
    ).generate_now

    assert_not_nil response

    # Access usage data from response
    if response.usage
      assert_instance_of Integer, response.usage["prompt_tokens"]
      assert_instance_of Integer, response.usage["completion_tokens"]
      assert_instance_of Integer, response.usage["total_tokens"]
    end

    # OpenRouter-specific cost tracking
    if response.metadata && response.metadata["usage"]
      usage = response.metadata["usage"]
      puts "Total cost: $#{usage['total_cost']}" if usage["total_cost"]
    end
  end
end
```

When `track_costs: true` is enabled in your agent configuration, OpenRouter will include detailed cost information in the response metadata.

::: details Usage Tracking Example
<!-- @include: @/parts/examples/open-router-integration-test.rb-test-tracks-usage-and-costs.md -->
:::

## Provider Preferences

Configure provider preferences for routing and data collection:

```ruby
class PreferenceAgent < ApplicationAgent
  generate_with :open_router,
    model: "openai/gpt-4o",
    provider_preferences: {
      allow: ["OpenAI", "Anthropic"],  # Only use these providers
      order: ["OpenAI"]                # Try OpenAI first
    }

  def analyze
    prompt(message: params[:message])
  end
end
```

For more information on provider preferences, see the [OpenRouter provider routing documentation](https://openrouter.ai/docs/provider-routing).

### Data Collection Policies

OpenRouter supports configuring data collection policies to control which providers can collect and use your data for training. According to the [OpenRouter documentation](https://openrouter.ai/docs/features/provider-routing#requiring-providers-to-comply-with-data-policies), you can configure this in three ways:

1. **Allow all providers** (default): All providers can collect data
2. **Deny all providers**: No providers can collect data
3. **Selective providers**: Only specified providers can collect data

#### Configuration Examples

```ruby
# Deny all data collection
class PrivateAgent < ApplicationAgent
  generate_with :open_router,
    model: "openai/gpt-4o",
    data_collection: "deny"

  def process
    prompt(message: params[:message])
  end
end

# Allow specific providers only
class SelectiveAgent < ApplicationAgent
  generate_with :open_router,
    model: "openai/gpt-4o",
    data_collection: ["OpenAI", "Anthropic"]

  def process
    prompt(message: params[:message])
  end
end
```

#### Real-World Example: Privacy-Focused Agent

Here's a complete example of an agent configured to handle sensitive data with strict privacy controls:

```ruby
class PrivacyFocusedAgent < ApplicationAgent
  generate_with :open_router,
    model: "openai/gpt-4o",
    data_collection: "deny",           # Prevent data collection
    require_parameters: true,          # Ensure parameter support
    fallback_models: ["openai/gpt-4o-mini"]

  def process_financial_data
    prompt(
      message: "Analyze this financial data: #{params[:data]}",
      data_collection: "deny"  # Ensure no training data collection
    )
  end

  def process_medical_records
    prompt(
      message: "Summarize this medical record: #{params[:record]}",
      data_collection: ["OpenAI"]  # Only allow OpenAI to access
    )
  end
end
```

Processing sensitive financial data:

```ruby
response = PrivacyFocusedAgent.process_financial_data(
  data: "Q4 earnings: $2.5M revenue, $800K expenses"
).generate_now

# Data is processed without being used for model training
puts response.message.content
```

Selective provider data collection for medical records:

```ruby
response = PrivacyFocusedAgent.process_medical_records(
  record: "Patient presents with symptoms..."
).generate_now

# Only OpenAI can access this data
puts response.message.content
```

You can configure data collection at multiple levels:

```ruby
# In config/active_agent.yml
development:
  open_router:
    api_key: <%= Rails.application.credentials.dig(:open_router, :api_key) %>
    model: openai/gpt-4o
    data_collection: deny  # Deny all providers from collecting data
    require_parameters: true  # Require model providers to support all specified parameters

# Or allow specific providers only
production:
  open_router:
    api_key: <%= Rails.application.credentials.dig(:open_router, :api_key) %>
    model: openai/gpt-4o
    data_collection: ["OpenAI", "Google"]  # Only these providers can collect data
    require_parameters: false  # Allow fallback to providers that don't support all parameters

# In your agent configuration
class PrivacyFocusedAgent < ApplicationAgent
  generate_with :open_router,
    model: "openai/gpt-4o",
    data_collection: "deny",  # Override for this specific agent
    require_parameters: true  # Ensure all parameters are supported
end
```

::: warning Privacy Considerations
When handling sensitive data, consider setting `data_collection: "deny"` to ensure your data is not used for model training. This is especially important for:
- Personal information
- Proprietary business data
- Medical or financial records
- Confidential communications
:::

::: tip
The `data_collection` parameter respects OpenRouter's provider compliance requirements. Providers that don't comply with your data collection policy will be automatically excluded from the routing pool.
:::

## Headers and Site Configuration

OpenRouter supports custom headers for tracking and attribution:

```ruby
class TrackedAgent < ApplicationAgent
  generate_with :open_router,
    model: "openai/gpt-4o",
    headers: {
      "HTTP-Referer": "https://your-app.com",
      "X-Title": "My Application"
    }

  def analyze
    prompt(message: params[:message])
  end
end
```

These headers help with tracking usage in the OpenRouter dashboard and provide attribution for your requests.

## Model Capabilities Detection

The provider automatically detects model capabilities:

```ruby
class CapabilityAwareAgent < ApplicationAgent
  generate_with :open_router, model: "openai/gpt-4o"

  def analyze_with_vision
    # The provider automatically detects vision support
    prompt(
      message: [
        { type: "text", text: "What's in this image?" },
        { type: "image_url", image_url: { url: params[:image_url] } }
      ]
    )
  end

  def structured_extraction
    # Automatically uses structured output if model supports it
    prompt(
      message: "Extract data from this text",
      output_schema: my_schema
    )
  end
end
```

The OpenRouter provider intelligently adapts to model capabilities, enabling or disabling features based on what the selected model supports.

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

- [Data Extraction Agent](/examples/data-extraction-agent) - Comprehensive examples of structured data extraction
- [Providers Overview](/framework/providers) - Understanding provider architecture
- [OpenRouter API Documentation](https://openrouter.ai/docs) - Official OpenRouter documentation
