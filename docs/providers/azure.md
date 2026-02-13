---
title: Azure OpenAI Provider
description: Integration with Azure OpenAI Service using dedicated provider with deployment-based endpoints, Azure-specific authentication, and OpenAI-compatible API features.
---
# {{ $frontmatter.title }}

The Azure OpenAI provider enables integration with Azure-hosted OpenAI models using a dedicated provider class. It handles Azure-specific authentication (api-key header), deployment-based endpoints, and API versioning while supporting the same features as the standard OpenAI Chat provider.

## Configuration

### Basic Setup

Configure Azure OpenAI in your agent:

```ruby
class MyAgent < ApplicationAgent
  generate_with :azure_openai,
    api_key: ENV["AZURE_OPENAI_API_KEY"],
    azure_resource: "mycompany",
    deployment_id: "gpt-4-deployment"
end
```

### Configuration File

Set up Azure OpenAI in `config/active_agent.yml`:

```yaml
azure_openai:
  service: "AzureOpenAI"
  api_key: <%= ENV["AZURE_OPENAI_API_KEY"] %>
  azure_resource: "mycompany"
  deployment_id: "gpt-4-deployment"
  api_version: "2024-10-21"
```

### Environment Variables

The provider checks these environment variables as fallbacks:

| Variable | Purpose |
|----------|---------|
| `AZURE_OPENAI_API_KEY` | API key for authentication |
| `AZURE_OPENAI_ACCESS_TOKEN` | Alternative to API key |
| `AZURE_OPENAI_API_VERSION` | API version (default: `2024-10-21`) |

## Key Differences from OpenAI

| Feature | OpenAI | Azure OpenAI |
|---------|--------|--------------|
| **Authentication** | `Authorization: Bearer` header | `api-key` header |
| **Endpoint** | `api.openai.com` | `{resource}.openai.azure.com/openai/deployments/{deployment}/` |
| **Model selection** | Model name (e.g., `gpt-4o`) | Deployment name from Azure portal |
| **API version** | Not required | Required query parameter (e.g., `2024-10-21`) |
| **Provider name** | `:openai` | `:azure_openai` |

## Provider-Specific Parameters

### Required Parameters

- **`api_key`** - Azure OpenAI API key (also accepts `access_token`)
- **`azure_resource`** - Your Azure resource name (e.g., `"mycompany"`)
- **`deployment_id`** - Your Azure deployment name (e.g., `"gpt-4-deployment"`)

### Optional Parameters

- **`api_version`** - Azure API version (default: `"2024-10-21"`)
- **`model`** - Model identifier for request payload
- **`max_retries`** - Maximum retry attempts
- **`timeout`** - Request timeout in seconds

### Inherited from OpenAI

Azure OpenAI inherits all Chat Completions API features from the OpenAI provider:

- **Sampling parameters** - `temperature`, `max_tokens`, `top_p`, `frequency_penalty`, `presence_penalty`
- **Response configuration** - `response_format` for structured output
- **Tools** - Function calling with the common tools format
- **Embeddings** - Text embedding generation

## Usage

### Basic Generation

```ruby
class SupportAgent < ApplicationAgent
  generate_with :azure_openai,
    api_key: ENV["AZURE_OPENAI_API_KEY"],
    azure_resource: "mycompany",
    deployment_id: "gpt-4-deployment",
    model: "gpt-4"

  def answer
    prompt(message: "How can I help you?")
  end
end

response = SupportAgent.answer.generate_now
response.message.content  #=> "I'm here to help! ..."
```

### With Tools

```ruby
class ToolAgent < ApplicationAgent
  generate_with :azure_openai,
    api_key: ENV["AZURE_OPENAI_API_KEY"],
    azure_resource: "mycompany",
    deployment_id: "gpt-4-deployment"

  def search_and_answer
    prompt(
      message: "Find information about Ruby on Rails",
      tools: [
        {
          name: "search",
          description: "Search for information",
          parameters: {
            type: "object",
            properties: {
              query: { type: "string", description: "Search query" }
            },
            required: ["query"]
          }
        }
      ]
    )
  end

  def search(query:)
    SearchService.find(query)
  end
end
```

## Provider Name Variants

Azure OpenAI can be referenced using several naming conventions:

```ruby
# All equivalent
generate_with :azure_openai
generate_with :azure_open_ai
generate_with :azure

# In config/active_agent.yml
azure_openai:
  service: "AzureOpenAI"
```

::: tip
Azure OpenAI may lag behind OpenAI's latest models and features. Check [Azure's model availability](https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/models) before planning deployments.
:::

::: warning Responses API
Azure OpenAI currently uses the Chat Completions API. The OpenAI Responses API features (web search, image generation, MCP) are not available through Azure.
:::

## Related Documentation

- [Providers Overview](/providers) - Compare all available providers
- [OpenAI Provider](/providers/open_ai) - Standard OpenAI provider documentation
- [Tools](/actions/tools) - Function calling with common format
- [Structured Output](/actions/structured_output) - JSON schema validation
- [Configuration](/framework/configuration) - Environment-specific settings
- [Azure OpenAI Documentation](https://learn.microsoft.com/en-us/azure/ai-services/openai/) - Official Azure docs
