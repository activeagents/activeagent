# SolidAgent - Automatic Persistence Layer

SolidAgent provides zero-configuration persistence for ActiveAgent, automatically tracking all agent activity, conversations, and metrics in your Rails application.

## What is SolidAgent?

SolidAgent is an automatic persistence layer that captures and stores:
- Every prompt and generation
- All tool/action executions  
- Complete conversation contexts
- Usage metrics and costs
- Performance data

All without requiring any configuration or callbacks from developers.

## Key Features

### 🚀 Zero Configuration
Just include the module - everything else is automatic:

<<< @/../test/solid_agent/persistable_test.rb#basic-usage{ruby}

### 📊 Complete Activity Tracking
Every aspect of agent activity is captured:
- Agent registrations
- Prompt contexts (system instructions, user messages, responses)
- Tool executions with parameters and results
- Token usage and generation costs
- Response times and performance metrics

### 🔍 Vector Search Built-in
Semantic search capabilities powered by Neighbor gem:

<<< @/../test/solid_agent/searchable_test.rb#vector-search{ruby}

### 🏗️ Works with Existing Models
Use your existing Rails models instead of SolidAgent tables:

<<< @/../test/solid_agent/contextual_test.rb#existing-models{ruby}

### 🛠️ Flexible Action System
Support for all tool types:
- Traditional function calls
- MCP (Model Context Protocol) servers
- Web browsing and search
- Computer use automation
- Custom actions

## Architecture Overview

SolidAgent follows a layered architecture that integrates seamlessly with ActiveAgent:

<<< @/../lib/solid_agent/architecture.rb#overview{ruby}

### Core Components

1. **Persistable Module** - Automatic interception and persistence
2. **PromptContext** - Complete interaction contexts (not just conversations)
3. **PromptGenerationCycle** - Request-response pattern tracking
4. **ActionExecution** - Comprehensive tool/action tracking
5. **Contextual/Searchable/Retrievable** - Integration modules for existing models

## Quick Start

### Installation

Add to your Gemfile:

<<< @/../test/solid_agent/test_gemfile.rb#installation{ruby}

Run the installation generator:

```bash
rails generate solid_agent:install
```

This creates:
- Database migrations for SolidAgent tables
- Configuration file at `config/solid_agent.yml`
- Initializer with default settings

### Basic Usage

<<< @/../test/solid_agent/documentation_examples_test.rb#basic-agent{ruby}

### Example Output

::: details Generation with Automatic Persistence
<!-- @include: @/parts/examples/solid-agent-basic-generation.md -->
:::

## How It Works

### Automatic Interception

SolidAgent uses Ruby's `prepend` to transparently intercept agent operations:

<<< @/../lib/solid_agent/persistable.rb#interception{ruby:line-numbers}

### Prompt-Generation Cycles

Every agent interaction follows a Request-Response pattern:

1. **Prompt Construction** - Building messages and context
2. **Generation** - Sending to AI provider
3. **Tool Execution** - Running requested actions
4. **Response** - Storing results

<<< @/../lib/solid_agent/models/prompt_generation_cycle.rb#lifecycle{ruby:line-numbers}

## PromptContext vs Conversation

SolidAgent uses **PromptContext** instead of "Conversation" because agent interactions are more than simple chats:

- System instructions and rules
- Developer directives and constraints
- Runtime state and variables
- Tool definitions and executions
- Multi-turn assistant responses
- Contextual metadata

<<< @/../test/solid_agent/models/prompt_context_test.rb#prompt-context{ruby:line-numbers}

## Next Steps

- [Persistable Module](./persistable.md) - Automatic persistence details
- [Contextual Integration](./contextual.md) - Using existing models
- [Action System](./actionable.md) - Defining and tracking actions
- [Vector Search](./searchable.md) - Semantic retrieval
- [Database Schema](./schema.md) - Table structure and relationships
- [Configuration](./configuration.md) - Customization options