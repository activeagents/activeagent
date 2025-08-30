# Intelligent Context Management

SolidAgent replaces fixed context windows with dynamic memory tools and data structures that agents use to manage their own context.

## Context as Tools

Agents interact with context through tools, not passive buffers:

<<< @/../lib/solid_agent/context/context_tools.rb#tools{ruby:line-numbers}

## Memory-Based Architecture

### Working Memory
Current task state and active context:

<<< @/../lib/solid_agent/memory/working_memory.rb#implementation{ruby:line-numbers}

### Episodic Memory
Specific past interactions indexed by time and relevance:

<<< @/../lib/solid_agent/memory/episodic_memory.rb#implementation{ruby:line-numbers}

### Semantic Memory
Knowledge graphs and learned relationships:

<<< @/../lib/solid_agent/memory/semantic_memory.rb#implementation{ruby:line-numbers}

## Context Management

### Dynamic Loading

Load context based on task requirements:

<<< @/../test/solid_agent/context_management_test.rb#dynamic-loading{ruby:line-numbers}

::: details Context Loading Example
<!-- @include: @/parts/examples/solid-agent-context-loading.md -->
:::

### Hierarchical Compression

Compress older context while maintaining key information:

<<< @/../lib/solid_agent/context/compression.rb#hierarchical{ruby:line-numbers}

### Relevance Scoring

Select context items by relevance to current task:

<<< @/../lib/solid_agent/context/relevance.rb#scoring{ruby:line-numbers}

## Memory Tools in Practice

### Research Agent Example

<<< @/../test/solid_agent/examples/research_agent_test.rb#memory-tools{ruby:line-numbers}

The agent uses memory tools to:
- Store research findings across sessions
- Retrieve relevant prior research
- Build knowledge graphs of topics
- Track which sources provided value

::: details Research Agent Output
<!-- @include: @/parts/examples/solid-agent-research-memory.md -->
:::

## Graph-Based Routing

### Action Graphs

Actions are nodes in a directed graph with relationships:

<<< @/../lib/solid_agent/graph/action_graph.rb#definition{ruby:line-numbers}

### Embedding Router

Route requests to actions based on semantic understanding:

<<< @/../lib/solid_agent/routing/embedding_router.rb#routing{ruby:line-numbers}

### Dynamic Tool Selection

Select tools at runtime based on task requirements:

<<< @/../test/solid_agent/tool_selection_test.rb#selection{ruby:line-numbers}

## Session Management

### Cross-Session Context

Maintain context across multiple sessions:

<<< @/../test/solid_agent/session_test.rb#cross-session{ruby:line-numbers}

### Context Branching

Branch context for parallel exploration:

<<< @/../test/solid_agent/session_test.rb#branching{ruby:line-numbers}

## Data Structures

### Memory Graph

Memories organized as a traversable graph:

<<< @/../lib/solid_agent/memory/memory_graph.rb#structure{ruby:line-numbers}

### Attention Indexes

Multiple indexes for efficient memory retrieval:

<<< @/../lib/solid_agent/memory/indexing.rb#indexes{ruby:line-numbers}

### Pattern Store

Learned patterns for strategy selection:

<<< @/../lib/solid_agent/memory/pattern_store.rb#patterns{ruby:line-numbers}

## Performance

### Memory Budget

Control memory usage with configurable limits:

<<< @/../lib/solid_agent/memory/budget.rb#configuration{ruby:line-numbers}

### Lazy Loading

Load memories only when accessed:

<<< @/../lib/solid_agent/memory/lazy_loading.rb#implementation{ruby:line-numbers}

### Caching Strategy

Cache frequently accessed memories:

<<< @/../lib/solid_agent/memory/cache.rb#strategy{ruby:line-numbers}

## Configuration

<<< @/../test/dummy/config/solid_agent.yml#memory-config{yaml}

## Integration with MCP

MCP tools become part of the action graph:

<<< @/../test/solid_agent/mcp_integration_test.rb#integration{ruby:line-numbers}

## Monitoring

Track memory and context usage:

<<< @/../lib/solid_agent/monitoring/memory_monitor.rb#metrics{ruby:line-numbers}

## Next Steps

- [Memory Tools API](./memory-tools.md)
- [Graph Routing](./graph-routing.md)
- [Session Management](./sessions.md)
- [Performance Tuning](./performance.md)