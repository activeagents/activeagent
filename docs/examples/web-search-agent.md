---
title: Web Search Agent
description: Web search capabilities through OpenAI's search models and tools. Access real-time web information using Chat Completions API or Responses API.
---
# {{ $frontmatter.title }}

Active Agent provides web search capabilities through integration with OpenAI's search models and tools. The Web Search Agent demonstrates how to leverage both Chat Completions API (with search-preview models) and Responses API (with web_search_preview tool) for accessing real-time web information.

## Overview

The Web Search Agent shows two approaches to web search:
- **Chat Completions API**: Uses special `gpt-4o-search-preview` model with built-in search
- **Responses API**: Uses regular models with `web_search_preview` tool for more control

## Features

- **Current Events Search** - Search for recent news and information
- **Configurable Context Size** - Control how much web context to include (low/medium/high)
- **Location-Based Search** - Provide user location for localized results
- **Multi-Tool Integration** - Combine web search with image generation and other tools

## Setup

Generate a web search agent:

```bash
rails generate active_agent:agent web_search search_current_events search_with_tools
```

## Agent Implementation

```ruby
# Example agent demonstrating web search capabilities
# Works with both Chat Completions API and Responses API
class WebSearchAgent < ApplicationAgent
  # For Chat API, use the search-preview models
  # For Responses API, use regular models with web_search_preview tool
  generate_with :openai, model: "gpt-4o"

  # Action for searching current events using Chat API with web search model
  def search_current_events
    @query = params[:query]
    @location = params[:location]

    # When using gpt-4o-search-preview model, web search is automatic
    prompt(
      message: @query,
      options: chat_api_search_options
    )
  end

  # Action for searching with Responses API (more flexible)
  def search_with_tools
    @query = params[:query]
    @context_size = params[:context_size] || "medium"

    prompt(
      message: @query,
      options: {
        use_responses_api: true,  # Force Responses API
        tools: [
          {
            type: "web_search_preview",
            search_context_size: @context_size
          }
        ]
      }
    )
  end

  # Action that combines web search with image generation (Responses API only)
  def research_and_visualize
    @topic = params[:topic]

    prompt(
      message: "Research #{@topic} and create a visualization",
      options: {
        model: "gpt-5",  # Responses API model
        use_responses_api: true,
        tools: [
          { type: "web_search_preview", search_context_size: "high" },
          { type: "image_generation", size: "1024x1024", quality: "high" }
        ]
      }
    )
  end

  private

  def chat_api_search_options
    options = {
      model: "gpt-4o-search-preview"  # Special model for Chat API web search
    }

    # Add web_search_options for Chat API
    if @location
      options[:web_search] = {
        user_location: format_location(@location)
      }
    else
      options[:web_search] = {}  # Enable web search with defaults
    end

    options
  end

  def format_location(location)
    # Format location for API
    {
      country: location[:country] || "US",
      city: location[:city],
      region: location[:region],
      timezone: location[:timezone]
    }.compact
  end
end
```

## Usage Examples

### Chat API with Search Preview Model

Use the Chat Completions API with the special search-preview model:

```ruby
response = WebSearchAgent.with(
  query: "Latest developments in AI for 2025"
).search_current_events.generate_now

puts response.message.content
# => Returns current information about AI developments
```

### Chat API with Location Context

Provide location information for localized search results:

```ruby
response = WebSearchAgent.with(
  query: "Best restaurants near me",
  location: {
    country: "US",
    city: "San Francisco",
    region: "CA"
  }
).search_current_events.generate_now

puts response.message.content
# => Returns San Francisco restaurant recommendations
```

### Responses API with Web Search Tool

Use the Responses API for more control over search context:

```ruby
response = WebSearchAgent.with(
  query: "Latest Ruby on Rails 8 features",
  context_size: "high"  # Options: low, medium, high
).search_with_tools.generate_now

puts response.message.content
# => Returns comprehensive information about Rails 8
```

### Combining Web Search with Image Generation

Use multiple tools together in the Responses API:

```ruby
response = WebSearchAgent.with(
  topic: "Climate Change Impact 2025"
).research_and_visualize.generate_now

# Response includes both research findings and generated visualizations
puts response.message.content
```

## Configuration Options

### Search Context Size

Control how much web context to include:

```ruby
{
  type: "web_search_preview",
  search_context_size: "high"  # Options: low, medium, high
}
```

- **low**: Minimal web context, faster responses
- **medium**: Balanced context and speed (default)
- **high**: Maximum web context, most comprehensive

### User Location

Provide location for localized results:

```ruby
{
  web_search: {
    user_location: {
      country: "US",
      city: "New York",
      region: "NY",
      timezone: "America/New_York"
    }
  }
}
```

## API Comparison

### Chat Completions API
- Uses `gpt-4o-search-preview` model
- Web search is automatic when model is specified
- Location can be provided via `web_search` options
- Simpler configuration for basic search needs

### Responses API
- Uses regular models (gpt-4o, gpt-5) with `web_search_preview` tool
- More control over search parameters
- Can combine with other tools (image generation, MCP, etc.)
- Required for multi-tool workflows

## Best Practices

### When to Use Chat API
- Simple web search queries
- When you need quick current information
- Location-based searches
- Straightforward question-answering

### When to Use Responses API
- Combining web search with other tools
- Need fine-grained control over search context
- Building complex workflows
- Integrating with MCP or custom tools

### Search Query Tips
- Be specific in your queries for better results
- Use natural language questions
- Specify time ranges when needed ("latest", "2025", "recent")
- Include context for ambiguous terms

## Integration with Rails

Use web search in your Rails controllers:

```ruby
class SearchController < ApplicationController
  def search
    response = WebSearchAgent.with(
      query: params[:q],
      context_size: params[:detail] || "medium"
    ).search_with_tools.generate_now

    render json: {
      query: params[:q],
      answer: response.message.content,
      sources: extract_sources(response)
    }
  end

  private

  def extract_sources(response)
    # Extract citation URLs from response if available
    response.message.content.scan(/\[(\d+)\]/).flatten
  end
end
```

## Provider Support

Web search capabilities require OpenAI provider:

```ruby
# config/application.rb
config.active_agent.providers = {
  openai: {
    api_key: ENV["OPENAI_API_KEY"]
  }
}
```

::: tip Model Availability
- **Chat API Search**: Requires `gpt-4o-search-preview` or newer
- **Responses API**: Requires `gpt-5` or compatible models
- Check OpenAI documentation for the latest model availability
:::

## Advanced Usage

### Caching Search Results

Cache expensive search operations:

```ruby
class WebSearchAgent < ApplicationAgent
  def cached_search
    @query = params[:query]
    cache_key = "web_search:#{Digest::MD5.hexdigest(@query)}"

    Rails.cache.fetch(cache_key, expires_in: 1.hour) do
      search_with_tools.generate_now
    end
  end
end
```

### Rate Limiting

Implement rate limiting for search requests:

```ruby
class WebSearchAgent < ApplicationAgent
  before_action :check_rate_limit

  private

  def check_rate_limit
    key = "search_rate:#{params[:user_id]}"
    count = Rails.cache.increment(key, 1, expires_in: 1.hour)

    if count > 100
      raise "Rate limit exceeded"
    end
  end
end
```

## Conclusion

The Web Search Agent demonstrates ActiveAgent's ability to leverage OpenAI's web search capabilities for accessing real-time information. Whether using the Chat API for simplicity or the Responses API for advanced workflows, web search integration enables agents to provide current, factual information beyond their training data.
