# The Complete Platform

ActiveAgent provides a three-layer architecture for building, persisting, and monitoring AI agents in production Rails applications.

## Architecture Overview

```
Application Layer (Your Code)
    ↓
ActiveAgent (Framework)
    ↓
SolidAgent (Persistence)
    ↓
ActiveSupervisor (Monitoring)
```

## ActiveAgent: The Framework

Rails-native agent framework with familiar patterns:

<<< @/../lib/active_agent/base.rb#framework{ruby:line-numbers}

Key features:
- Agents as controllers
- Actions as tools
- Views as prompts
- Generation providers for multiple AI services

## SolidAgent: Automatic Persistence

Zero-configuration persistence layer:

<<< @/../lib/solid_agent/persistable.rb#automatic{ruby:line-numbers}

Provides:
- Automatic activity tracking
- Memory management tools
- Graph-based routing
- Session continuity

## ActiveSupervisor: Production Monitoring

Cloud monitoring service for production agents:

<<< @/../lib/active_supervisor_client.rb#client{ruby:line-numbers}

Features:
- Real-time metrics
- Cost tracking
- Performance monitoring
- Cross-application analytics

## How They Work Together

### 1. Development Flow

Create agents with ActiveAgent:

<<< @/../test/agents/example_agent_test.rb#development{ruby:line-numbers}

### 2. Automatic Persistence

SolidAgent captures everything automatically:

<<< @/../test/solid_agent/integration_test.rb#persistence{ruby:line-numbers}

### 3. Production Monitoring

ActiveSupervisor provides visibility:

<<< @/../test/active_supervisor/monitoring_test.rb#monitoring{ruby:line-numbers}

::: details Complete Flow Example
<!-- @include: @/parts/examples/platform-complete-flow.md -->
:::

## Memory and Intelligence

### Memory Tools

Agents use memory as active tools:

<<< @/../test/solid_agent/memory_integration_test.rb#memory-tools{ruby:line-numbers}

### Graph Routing

Intelligent action selection through graphs:

<<< @/../test/solid_agent/graph_integration_test.rb#graph-routing{ruby:line-numbers}

### Context Management

Dynamic context through memory:

<<< @/../test/solid_agent/context_integration_test.rb#context{ruby:line-numbers}

## Configuration

### Rails Application

<<< @/../test/dummy/config/active_agent.yml#platform-config{yaml}

### SolidAgent Settings

<<< @/../test/dummy/config/solid_agent.yml#solid-config{yaml}

### ActiveSupervisor Connection

<<< @/../test/dummy/config/active_supervisor.yml#supervisor-config{yaml}

## Database Architecture

### Core Tables

SolidAgent creates these tables:
- `solid_agent_agents` - Registered agents
- `solid_agent_prompt_contexts` - Complete contexts
- `solid_agent_messages` - All message types
- `solid_agent_generations` - AI responses
- `solid_agent_action_executions` - Tool calls
- `solid_agent_memories` - Agent memory
- `solid_agent_action_graphs` - Routing graphs

### Relationships

<<< @/../lib/solid_agent/models/relationships.rb#schema{ruby:line-numbers}

## Deployment

### Development

Local development with all components:

```bash
# Install dependencies
bundle install

# Run migrations
rails solid_agent:install
rails db:migrate

# Start server
rails server
```

### Production

Deploy with monitoring:

<<< @/../config/deploy.rb#production{ruby:line-numbers}

## Performance

### Benchmarks

Performance metrics across the stack:

<<< @/../test/performance/platform_benchmark.rb#benchmarks{ruby:line-numbers}

### Optimization

Key optimization points:
- Async persistence for high throughput
- Memory budgets for resource control
- Graph caching for routing speed
- Connection pooling for monitoring

## Real-World Example

### E-commerce Assistant

Complete agent with memory, routing, and monitoring:

<<< @/../test/examples/ecommerce_agent_test.rb#complete{ruby:line-numbers}

::: details E-commerce Assistant Output
<!-- @include: @/parts/examples/platform-ecommerce.md -->
:::

## Migration Path

### From Basic ActiveAgent

1. Add SolidAgent gem
2. Include Persistable module
3. Run migrations
4. Everything else is automatic

### Adding Monitoring

1. Sign up for ActiveSupervisor
2. Add credentials
3. Deploy
4. View dashboard

## API Documentation

### ActiveAgent API

Core agent methods:

<<< @/../lib/active_agent/base.rb#api{ruby:line-numbers}

### SolidAgent API

Memory and routing tools:

<<< @/../lib/solid_agent/api.rb#methods{ruby:line-numbers}

### ActiveSupervisor API

Monitoring client:

<<< @/../lib/active_supervisor_client/api.rb#client{ruby:line-numbers}

## Best Practices

1. **Use memory tools** - Don't rely on context windows
2. **Define action graphs** - Enable intelligent routing
3. **Monitor in production** - Track costs and performance
4. **Test with persistence** - Ensure tracking works
5. **Configure budgets** - Control resource usage

## Ecosystem

### Compatible Gems

- `neighbor` - Vector operations
- `pg_vector` - PostgreSQL vectors
- `sidekiq` - Background jobs
- `good_job` - PostgreSQL job queue

### MCP Integration

Use MCP servers as tools:

<<< @/../test/solid_agent/mcp_test.rb#mcp-tools{ruby:line-numbers}

## Support

- [Documentation](https://docs.activeagents.ai)
- [GitHub Issues](https://github.com/activeagent/activeagent/issues)
- [Discord Community](https://discord.gg/activeagent)

## Next Steps

- [Getting Started](../getting-started.md)
- [Memory Architecture](./memory-architecture.md)
- [Graph Routing](./graph-routing.md)
- [Production Deployment](./deployment.md)