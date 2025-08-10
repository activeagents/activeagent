---
title: Tools and Actions
---
# {{ $frontmatter.title }}

Active Agent supports tool/function calling, allowing agents to interact with external services and perform actions.

## Tool Support

Agents can define and use tools to extend their capabilities:

<<< @/../test/dummy/app/agents/support_agent.rb {ruby}

## Tool Usage Example

Here's how an agent uses tools to fulfill user requests:

<<< @/../test/agents/support_agent_test.rb#support_agent_tool_call {ruby:line-numbers}

### Tool Call Response

When a tool is called, the response includes the tool's output in the conversation:

<<< @/../test/agents/support_agent_test.rb#support_agent_tool_call_response {ruby:line-numbers}

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

## Implementing Tools

Tools are defined as methods in your agent class. The tool's JSON schema is defined in the corresponding view template:

### Tool Implementation

<<< @/../test/dummy/app/agents/support_agent.rb#5-9 {ruby:line-numbers}

### Tool Schema Definition

<<< @/../test/dummy/app/views/support_agent/get_cat_image.json.erb {erb}