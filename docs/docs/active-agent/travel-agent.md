# TravelAgent Example

The TravelAgent demonstrates how to build an AI agent that can interact with users through natural language and perform specific actions via tool calling. This agent showcases the ActiveAgent framework's ability to:

- Define actions that can be called by an LLM as tools
- Handle different response formats (HTML, text, JSON)
- Process parameters passed from the LLM to controller actions
- Maintain conversation context across multiple tool calls

## Agent Definition

<<< @/../test/dummy/app/agents/travel_agent.rb {ruby}

## Tool Schemas

Each action is automatically exposed as a tool to the LLM through JSON schemas. The schemas define the parameters that the LLM should provide when calling each tool.

### Search Action Schema

<<< @/../test/dummy/app/views/travel_agent/search.json.jbuilder {ruby}

### Book Action Schema

<<< @/../test/dummy/app/views/travel_agent/book.json.jbuilder {ruby}

### Confirm Action Schema

<<< @/../test/dummy/app/views/travel_agent/confirm.json.jbuilder {ruby}

## View Templates

Each action has corresponding view templates that format the response:

### search.html.erb

<<< @/../test/dummy/app/views/travel_agent/search.html.erb {erb}

### book.text.erb

<<< @/../test/dummy/app/views/travel_agent/book.text.erb {erb}

### confirm.text.erb

<<< @/../test/dummy/app/views/travel_agent/confirm.text.erb {erb}

## Usage Examples

### Basic LLM Interaction

When you create a prompt context and generate a response, the LLM can call the TravelAgent's tools:

<<< @/../test/agents/travel_agent_test.rb#travel_agent_search_llm {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/test-travel-agent-search-action-with-LLM-interaction-test-travel-agent-search-action-with-LLM-interaction.md -->
:::

### Booking a Flight

<<< @/../test/agents/travel_agent_test.rb#travel_agent_book_llm {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/test-travel-agent-book-action-with-LLM-interaction-travel_agent_book_llm.md -->
:::

### Confirming a Booking

<<< @/../test/agents/travel_agent_test.rb#travel_agent_confirm_llm {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/test-travel-agent-confirm-action-with-LLM-interaction-test-travel-agent-confirm-action-with-LLM-interaction.md -->
:::

### Full Conversation Flow

<<< @/../test/agents/travel_agent_test.rb#travel_agent_conversation_flow {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/test-travel-agent-full-conversation-flow-with-LLM-test-travel-agent-full-conversation-flow-with-LLM.md -->
:::

### Direct Action Invocation

You can also call actions directly with parameters:

<<< @/../test/agents/travel_agent_test.rb#travel_agent_search_html {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/test-travel-agent-search-view-renders-HTML-format-test-travel-agent-search-view-renders-HTML-format.md -->
:::

## How Tool Calling Works

### Tool Call Structure

<<< @/../test/agents/travel_agent_tool_call_test.rb#4-14 {ruby:line-numbers}

### Parameter Processing

<<< @/../test/agents/travel_agent_tool_call_test.rb#52-90 {ruby:line-numbers}

The framework automatically:

1. **Schema Discovery**: Discovers all public instance methods (actions) and loads their JSON schemas
2. **LLM Tool Selection**: The LLM receives available tools and decides which to call
3. **Parameter Passing**: Tool parameters are set on the controller's `params` hash
4. **Action Execution**: The framework executes the action and updates context
5. **Response Generation**: The action renders its view template

## Multi-Format Support

The TravelAgent demonstrates how different actions can use different response formats:

<<< @/../test/agents/travel_agent_test.rb#travel_agent_multi_format {ruby:line-numbers}

- **Search**: Uses HTML format for rich UI display
- **Book**: Uses text format for simple confirmation messages  
- **Confirm**: Uses text format for final booking confirmation

## Testing with VCR

The TravelAgent tests use VCR to record actual LLM interactions. The cassettes capture real OpenAI API calls showing how the LLM:
- Receives the tool schemas
- Decides which action to call
- Passes the appropriate parameters

## Best Practices

1. **Parameter Validation**: Always validate and sanitize parameters received from the LLM
2. **Error Handling**: Provide helpful error messages when required parameters are missing
3. **Idempotency**: Design actions to be safely repeatable
4. **Context Preservation**: The framework automatically maintains conversation context across tool calls
5. **Testing**: Use VCR to record and replay LLM interactions for consistent testing