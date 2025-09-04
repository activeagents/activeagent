# SolidAgent Architecture

SolidAgent provides automatic persistence and monitoring capabilities for ActiveAgent applications through a zero-configuration design.

## Architecture Overview

The ActiveAgent platform consists of three complementary layers:

<<< @/../test/solid_agent_concept_test.rb#data-flow-example{ruby:line-numbers}

::: details Complete Data Flow
<!-- @include: @/parts/examples/solid_agent_concept_test-complete_data_flow_from_agent_to_monitoring.md -->
:::

## Core Concepts

### Automatic Persistence

SolidAgent requires zero configuration - just include the module:

<<< @/../test/solid_agent_concept_test.rb#automatic-persistence-demo{ruby:line-numbers}

::: details Automatic Persistence Output
<!-- @include: @/parts/examples/solid_agent_concept_test-demonstrates_automatic_persistence_concept.md -->
:::

### PromptContext vs Conversation

A key architectural decision is using PromptContext instead of Conversation:

<<< @/../test/solid_agent_concept_test.rb#prompt-context-vs-conversation{ruby:line-numbers}

::: details PromptContext Explanation
<!-- @include: @/parts/examples/solid_agent_concept_test-prompt_context_encompasses_more_than_conversations.md -->
:::

## Integration with ActiveAgent

### Conditional Inclusion

SolidAgent integrates seamlessly when available:

<<< @/../lib/active_agent/base.rb#34-43{ruby:line-numbers}

### Prompt-Generation Cycle Tracking

The framework automatically tracks prompt-generation cycles:

<<< @/../lib/active_agent/base.rb#67-94{ruby:line-numbers}

## Action System

### Comprehensive Action Types

SolidAgent supports all modern AI action types:

<<< @/../test/solid_agent_concept_test.rb#action-types-demo{ruby:line-numbers}

::: details Supported Action Types
<!-- @include: @/parts/examples/solid_agent_concept_test-comprehensive_action_type_support.md -->
:::

## Deployment Options

### Dual Deployment Model

ActiveSupervisor supports both cloud and self-hosted deployment:

<<< @/../test/solid_agent_concept_test.rb#deployment-options{ruby:line-numbers}

::: details Deployment Configuration
<!-- @include: @/parts/examples/solid_agent_concept_test-dual_deployment_options.md -->
:::

## Zero Configuration Design

### Simplicity First

The entire setup requires minimal configuration:

<<< @/../test/solid_agent_concept_test.rb#zero-config-example{ruby:line-numbers}

::: details Zero Configuration Details
<!-- @include: @/parts/examples/solid_agent_concept_test-zero_configuration_required.md -->
:::

## Database Schema

### Core Tables

The persistence layer uses a comprehensive schema:

```sql
-- Agent registry
CREATE TABLE solid_agent_agents (
  id BIGSERIAL PRIMARY KEY,
  class_name VARCHAR NOT NULL UNIQUE,
  display_name VARCHAR,
  description TEXT,
  status VARCHAR DEFAULT 'active',
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- PromptContext (not Conversation!)
CREATE TABLE solid_agent_prompt_contexts (
  id BIGSERIAL PRIMARY KEY,
  agent_id BIGINT REFERENCES solid_agent_agents(id),
  contextual_type VARCHAR, -- polymorphic
  contextual_id BIGINT,    -- polymorphic
  context_type VARCHAR DEFAULT 'runtime',
  status VARCHAR DEFAULT 'active',
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- Messages
CREATE TABLE solid_agent_messages (
  id BIGSERIAL PRIMARY KEY,
  prompt_context_id BIGINT REFERENCES solid_agent_prompt_contexts(id),
  role VARCHAR NOT NULL, -- system, user, assistant, tool, developer
  content TEXT,
  content_type VARCHAR DEFAULT 'text',
  position INTEGER NOT NULL,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL
);

-- Action Executions (comprehensive)
CREATE TABLE solid_agent_action_executions (
  id BIGSERIAL PRIMARY KEY,
  message_id BIGINT REFERENCES solid_agent_messages(id),
  action_name VARCHAR NOT NULL,
  action_type VARCHAR NOT NULL, -- tool, mcp_tool, graph_retrieval, web_search, etc.
  action_id VARCHAR UNIQUE,
  parameters JSONB,
  status VARCHAR DEFAULT 'pending',
  executed_at TIMESTAMP,
  result_message_id BIGINT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL
);

-- Prompt-Generation Cycles
CREATE TABLE solid_agent_prompt_generation_cycles (
  id BIGSERIAL PRIMARY KEY,
  prompt_context_id BIGINT REFERENCES solid_agent_prompt_contexts(id),
  agent_id BIGINT REFERENCES solid_agent_agents(id),
  status VARCHAR DEFAULT 'prompting',
  prompt_constructed_at TIMESTAMP,
  generation_started_at TIMESTAMP,
  generation_completed_at TIMESTAMP,
  total_duration_ms INTEGER,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL
);

-- Generations
CREATE TABLE solid_agent_generations (
  id BIGSERIAL PRIMARY KEY,
  prompt_context_id BIGINT REFERENCES solid_agent_prompt_contexts(id),
  cycle_id BIGINT REFERENCES solid_agent_prompt_generation_cycles(id),
  provider VARCHAR NOT NULL,
  model VARCHAR NOT NULL,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  total_tokens INTEGER,
  cost DECIMAL(10,6),
  latency_ms INTEGER,
  status VARCHAR DEFAULT 'pending',
  error_message TEXT,
  created_at TIMESTAMP NOT NULL
);
```

## Implementation Status

### What's Been Built

The core SolidAgent implementation includes:

1. **Automatic Persistence** - Zero-configuration tracking
2. **PromptContext Model** - Comprehensive interaction context
3. **Action System** - Flexible action definition
4. **Integration Modules** - Contextual, Retrievable, Searchable
5. **Test Suite** - Comprehensive testing

### Files Created

Core implementation files:
- `/lib/solid_agent/persistable.rb` - Automatic persistence module
- `/lib/solid_agent/models/prompt_context.rb` - PromptContext model
- `/lib/solid_agent/models/action_execution.rb` - Action tracking
- `/lib/solid_agent/actionable.rb` - Action definition system

## Testing

### Running Tests

The concept tests demonstrate the architecture:

```bash
# Run concept tests
bin/test test/solid_agent_concept_test.rb

# Run all tests
bin/test
```

### Test Coverage

Tests cover:
- Automatic persistence behavior
- PromptContext vs Conversation distinction  
- Comprehensive action types
- Deployment configurations
- Zero-configuration design

## Next Steps

1. **Package as Gem** - Create solid_agent gem
2. **ActivePrompt UI** - Build dashboard interface
3. **ActiveSupervisor** - Deploy monitoring service
4. **Documentation** - Complete API documentation
5. **Integration Examples** - Real-world usage patterns