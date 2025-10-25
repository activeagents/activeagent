---
title: Tools and Actions
---
# {{ $frontmatter.title }}

ActiveAgent supports tool/function calling, allowing agents to interact with external services and perform actions during multi-turn conversations.

## Overview

Tools enable agents to:
- Call actions during generation
- Receive tool results as part of the conversation
- Continue generation with tool results to provide final answers
- Chain multiple tool calls to solve complex tasks

## How Tool Calling Works

When an agent needs to use a tool during generation:

1. The agent requests a tool call with specific parameters
2. ActiveAgent executes the corresponding action method
3. The tool result is added to the conversation as a "tool" message
4. Generation continues automatically with the tool result
5. The agent can make additional tool calls or provide a final response

## Basic Example

Here's a support agent with a simple tool that fetches cat images:

```ruby
class SupportAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini", instructions: "You're a support agent. Your job is to help users with their questions."

  def get_cat_image
    prompt(content_type: "image_url", context_id: params[:context_id]) do |format|
      format.text { render plain: CatImageService.fetch_image_url }
    end
  end
end
```

The agent can call the `get_cat_image` tool when needed:

```ruby
# Agent receives request and calls the tool
response = SupportAgent.with(
  message: "Can you show me a cat picture?",
  context_id: "user_123"
).get_cat_image.generate_now

# The agent calls the get_cat_image action and uses the result
```

## Tool Usage Example

Here's how an agent uses tools to fulfill user requests:

```ruby
message = "Show me a cat"
prompt = SupportAgent.prompt(message: message)
```

### Tool Call Response

When a tool is called, the response includes the tool's output in the conversation:

```ruby
response = prompt.generate_now
```

::: details Response Example
<!-- @include: @/parts/examples/support-agent-test.rb-test-it-renders-a-prompt-context-generates-a-response-with-a-tool-call-and-performs-the-requested-actions.md -->
:::

## Tool Response Structure

When tools are used, the response includes:
- **System Message**: Initial instructions for the agent
- **User Message**: The original user request
- **Assistant Message**: The agent's decision to use a tool
- **Tool Message**: The result from the tool execution

The final response contains 4 messages showing the complete tool interaction flow.

## Tool Response Formats

Tools can return different types of content:

### Simple Action Response

The support agent's cat image tool returns image URLs:

```ruby
class SupportAgent < ApplicationAgent
  def get_cat_image
    prompt(content_type: "image_url", context_id: params[:context_id]) do |format|
      format.text { render plain: CatImageService.fetch_image_url }
    end
  end
end
```

### Using Concerns for Tool Organization

Complex agents can use concerns to organize multiple tools:

```ruby
class ResearchAgent < ApplicationAgent
  include ResearchTools

  # Configure the agent to use OpenAI with specific settings
  generate_with :openai, model: "gpt-4o"

  # Configure research tools at the class level
  configure_research_tools(
    enable_web_search: true,
    mcp_servers: [ "arxiv", "github" ],
    default_search_context: "high"
  )

  # Agent-specific action that uses both concern tools and custom logic
  def comprehensive_research
    @topic = params[:topic]
    @depth = params[:depth] || "detailed"

    # This action combines multiple tools
    prompt(
      message: "Conduct comprehensive research on: #{@topic}",
      tools: build_comprehensive_tools
    )
  end

  def literature_review
    @topic = params[:topic]
    @sources = params[:sources] || [ "arxiv", "pubmed" ]

    # Use the concern's search_with_mcp_sources internally
    mcp_tools = build_mcp_tools(@sources)

    prompt(
      message: "Conduct a literature review on: #{@topic}\nFocus on peer-reviewed sources from the last 5 years.",
      tools: [
        { type: "web_search_preview", search_context_size: "high" },
        *mcp_tools
      ]
    )
  end

  # ...
end
```

The research agent includes the `ResearchTools` concern which provides multiple tool actions like `search_academic_papers` and `search_with_mcp_sources`.

## Implementing Tools

Tools are defined as methods in your agent class. The tool's JSON schema is defined in the corresponding view template:

### Tool Implementation

```ruby
def get_cat_image
  prompt(content_type: "image_url", context_id: params[:context_id]) do |format|
    format.text { render plain: CatImageService.fetch_image_url }
  end
end
```

### Tool Schema Definition

Define tool schemas using JSON views to describe parameters:

```erb
<%= {
  type: :function,
  function: {
    name: 'get_cat_image',
    description: "This action takes no params and gets a random cat image and returns it as a base64 string.",
    parameters: {
      type: :object,
      properties: {}
    }
  }
}.to_json.html_safe %>
```

This schema tells the AI model:
- The tool name and description
- Required and optional parameters
- Parameter types and descriptions

### More Complex Tool Schema

For tools with parameters, define them in the schema:

```ruby
json.type "function"
json.function do
  json.name action_name
  json.description "Search for academic papers on a given topic with optional filters"
  json.parameters do
    json.type "object"
    json.properties do
      json.query do
        json.type "string"
        json.description "The search query for academic papers"
      end
      json.year_from do
        json.type "integer"
        json.description "Start year for publication date filter"
      end
      json.year_to do
        json.type "integer"
        json.description "End year for publication date filter"
      end
      json.field do
        json.type "string"
        json.description "Academic field or discipline"
        json.enum [ "computer_science", "medicine", "physics", "biology", "chemistry", "mathematics", "engineering", "social_sciences" ]
      end
    end
    json.required [ "query" ]
  end
end
```

## Built-in Tools

Some providers support built-in tools that don't require custom implementation:

```ruby
class ResearchAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"

  def comprehensive_research
    @topic = params[:topic]

    # Use built-in web search tool
    prompt(
      message: "Research: #{@topic}",
      tools: [
        { type: "web_search_preview", search_context_size: "high" },
        { type: "image_generation" }
      ]
    )
  end
end
```

For more details on built-in tools, see the [OpenAI Provider documentation](/providers/openai-provider#built-in-tools-responses-api).

## Implementation Details

The tool calling flow is handled by the `perform_generation` method:

1. **Initial Generation**: The agent receives the user message and generates a response
2. **Tool Request**: If the response includes `requested_actions`, tools are called
3. **Tool Execution**: Each action is executed via `perform_action`
4. **Result Handling**: Tool results are added as "tool" messages
5. **Continuation**: Generation continues with `continue_generation`
6. **Completion**: The process repeats until no more tools are requested

This creates a natural conversation flow where the agent can gather information through tools before providing a final answer. [Understanding the complete generation cycle →](/agents/generation)

## See Also

- [Using Concerns](/framework/concerns) - Organizing tools with concerns
- [OpenAI Built-in Tools](/providers/openai-provider#built-in-tools-responses-api) - Provider-specific tool features
- [Agent Generation](/agents/generation) - Complete generation cycle documentation
