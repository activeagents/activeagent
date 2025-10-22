# Tool Calling

ActiveAgent supports multi-turn tool calling, allowing agents to:
- Call tools (agent actions) during generation
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

<<< @/../test/dummy/app/agents/support_agent.rb{ruby:line-numbers}

The agent can call the `get_cat_image` tool when needed:

```ruby
# Agent receives request and calls the tool
response = SupportAgent.with(
  message: "Can you show me a cat picture?",
  context_id: "user_123"
).get_cat_image.generate_now

# The agent calls the get_cat_image action and uses the result
```

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

<<< @/../test/dummy/app/agents/research_agent.rb#1-40{ruby:line-numbers}

The research agent includes the `ResearchTools` concern which provides multiple tool actions like `search_academic_papers` and `search_with_mcp_sources`.

## Tool Schemas

Define tool schemas using JSON views to describe parameters. [Learn more about tool implementation →](/actions/tools)

<<< @/../test/dummy/app/views/support_agent/get_cat_image.json.erb{ruby:line-numbers}

This schema tells the AI model:
- The tool name and description
- Required and optional parameters
- Parameter types and descriptions

### More Complex Tool Schema

For tools with parameters, define them in the schema:

<<< @/../test/dummy/app/views/research_agent/search_academic_papers.json.jbuilder{ruby:line-numbers}

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

- [Tools Documentation](/actions/tools) - Detailed guide on implementing tools
- [Using Concerns](/framework/concerns) - Organizing tools with concerns
- [OpenAI Built-in Tools](/providers/openai-provider#built-in-tools-responses-api) - Provider-specific tool features
