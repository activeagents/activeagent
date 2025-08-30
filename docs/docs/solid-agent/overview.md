# SolidAgent - Automatic Persistence for ActiveAgent

SolidAgent provides zero-configuration persistence for ActiveAgent, automatically tracking all agent activity without requiring any callbacks or configuration.

## Installation

Add SolidAgent to your Gemfile:

<<< @/../test/solid_agent/test_gemfile.rb#installation{ruby}

Run the installation generator:

<<< @/../test/solid_agent/test_installation.sh#install{bash}

## Basic Usage

Just include the module in your agent:

<<< @/../test/solid_agent/persistable_test.rb#test-agent{ruby}

That's it! Everything is now automatically persisted.

## What Gets Persisted

SolidAgent automatically tracks:
- Agent registrations
- Prompt contexts (not just "conversations")
- All message types (system, user, assistant, tool)
- Generation metrics and responses
- Action/tool executions
- Usage metrics and costs

### Example Output

::: details Persistence Example
<!-- @include: @/parts/examples/solid-agent-persistence-example.md -->
:::

## How It Works

### Automatic Interception

SolidAgent uses Ruby's `prepend` to transparently intercept agent methods:

<<< @/../lib/solid_agent/persistable.rb#automatic-persistence{ruby:line-numbers}

### Prompt-Generation Cycles

Following the HTTP Request-Response pattern, SolidAgent tracks complete cycles:

<<< @/../lib/solid_agent/models/prompt_generation_cycle.rb#cycle-tracking{ruby:line-numbers}

## PromptContext vs Conversation

SolidAgent uses **PromptContext** instead of "Conversation" because agent interactions encompass:
- System instructions
- Developer directives  
- Runtime state
- Tool executions
- Assistant responses

<<< @/../lib/solid_agent/models/prompt_context.rb#prompt-context-definition{ruby:line-numbers}

## Action Tracking

All action types are automatically tracked:

<<< @/../lib/solid_agent/models/action_execution.rb#action-types{ruby:line-numbers}

### Supported Action Types

- Traditional tool/function calls
- MCP (Model Context Protocol) tools
- Graph retrieval operations
- Web search and browsing
- Computer use automation
- API calls
- Database queries
- Custom actions

## Configuration

While SolidAgent works with zero configuration, you can customize if needed:

<<< @/../test/dummy/config/solid_agent.yml#configuration{yaml}

## Testing

SolidAgent includes comprehensive test coverage:

<<< @/../test/solid_agent/persistable_test.rb#test-automatic-registration{ruby:line-numbers}

::: details Test Output
<!-- @include: @/parts/examples/solid-agent-test-output.md -->
:::

## Database Schema

SolidAgent creates these tables automatically:

<<< @/../lib/solid_agent/generators/install/templates/create_solid_agent_tables.rb#schema{sql:line-numbers}

## Next Steps

- [Using with Existing Models](./contextual.md)
- [Vector Search](./searchable.md)
- [Defining Actions](./actionable.md)
- [ActiveSupervisor Integration](./supervisor.md)