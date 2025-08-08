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

Here's a simple calculator agent that can perform arithmetic operations:

<<< @/../test/dummy/app/agents/calculator_agent.rb#1-10 {ruby:line-numbers}

When asked to add numbers, the agent will:

<<< @/../test/agents/multi_turn_tool_test.rb#multi_turn_basic {ruby:line-numbers}

The conversation flow includes:

::: details Response Example
<!-- @include: @/parts/examples/multi-turn-tool-test-agent-performs-tool-call-and-continues-generation-with-result.md -->
:::

## Chaining Multiple Tool Calls

Agents can chain multiple tool calls to solve complex tasks:

<<< @/../test/agents/multi_turn_tool_test.rb#multi_turn_chain {ruby:line-numbers}

This results in a sequence of tool calls:

::: details Response Example
<!-- @include: @/parts/examples/multi-turn-tool-test-agent-chains-multiple-tool-calls-for-complex-task.md -->
:::

## Tool Response Formats

Tools can return different types of content:

### Plain Text Responses

<<< @/../test/dummy/app/agents/calculator_agent.rb#5-10 {ruby:line-numbers}

### HTML/View Responses

<<< @/../test/dummy/app/agents/weather_agent.rb#10-14 {ruby:line-numbers}

The weather report view:

<<< @/../test/dummy/app/views/weather_agent/weather_report.html.erb {html:line-numbers}

## Error Handling

Tools should handle errors gracefully:

<<< @/../test/dummy/app/agents/calculator_agent.rb#23-34 {ruby:line-numbers}

When an error occurs, the agent receives the error message and can provide appropriate guidance to the user.

## Tool Schemas

Define tool schemas using JSON views to describe parameters:

<<< @/../test/dummy/app/views/calculator_agent/add.json.jbuilder {ruby:line-numbers}

This schema tells the AI model:
- The tool name and description
- Required and optional parameters
- Parameter types and descriptions

## Implementation Details

The tool calling flow is handled by the `perform_generation` method:

1. **Initial Generation**: The agent receives the user message and generates a response
2. **Tool Request**: If the response includes `requested_actions`, tools are called
3. **Tool Execution**: Each action is executed via `perform_action`
4. **Result Handling**: Tool results are added as "tool" messages
5. **Continuation**: Generation continues with `continue_generation`
6. **Completion**: The process repeats until no more tools are requested

This creates a natural conversation flow where the agent can gather information through tools before providing a final answer.