# Action Graph as Rails Cache

SolidAgent implements action graphs using familiar Rails cache patterns, making it natural for Rails developers to work with complex agent routing.

## Rails Cache Pattern

Just like Rails cache, action graphs provide a familiar interface:

<<< @/../lib/solid_agent/action_graph/cache_interface.rb#interface{ruby:line-numbers}

## Basic Usage

### Writing to the Graph

<<< @/../test/solid_agent/action_graph_cache_test.rb#write{ruby:line-numbers}

### Reading from the Graph

<<< @/../test/solid_agent/action_graph_cache_test.rb#read{ruby:line-numbers}

### Fetch Pattern

<<< @/../test/solid_agent/action_graph_cache_test.rb#fetch{ruby:line-numbers}

## Graph Store Implementations

### Memory Store

For development and testing:

<<< @/../lib/solid_agent/action_graph/memory_store.rb#implementation{ruby:line-numbers}

### Redis Store

For production with shared state:

<<< @/../lib/solid_agent/action_graph/redis_store.rb#implementation{ruby:line-numbers}

### Database Store

For persistence and analytics:

<<< @/../lib/solid_agent/action_graph/database_store.rb#implementation{ruby:line-numbers}

## Cache Keys

### Action Keys

Actions are keyed by agent and name:

<<< @/../lib/solid_agent/action_graph/key_generation.rb#action-keys{ruby:line-numbers}

### Relationship Keys

Relationships between actions:

<<< @/../lib/solid_agent/action_graph/key_generation.rb#relationship-keys{ruby:line-numbers}

### Version Keys

Support for versioned graphs:

<<< @/../lib/solid_agent/action_graph/key_generation.rb#version-keys{ruby:line-numbers}

## Expiration and TTL

### Time-Based Expiration

<<< @/../test/solid_agent/action_graph_cache_test.rb#expiration{ruby:line-numbers}

### Conditional Expiration

<<< @/../test/solid_agent/action_graph_cache_test.rb#conditional{ruby:line-numbers}

## Graph Operations

### Traversal

Navigate the graph like a cache hierarchy:

<<< @/../test/solid_agent/action_graph_traversal_test.rb#traversal{ruby:line-numbers}

### Bulk Operations

Efficient bulk reads and writes:

<<< @/../test/solid_agent/action_graph_cache_test.rb#bulk{ruby:line-numbers}

### Atomic Operations

Thread-safe graph modifications:

<<< @/../test/solid_agent/action_graph_cache_test.rb#atomic{ruby:line-numbers}

## Configuration

Configure like Rails cache:

<<< @/../test/dummy/config/solid_agent.yml#action-graph-cache{yaml}

## Integration with Rails Cache

### Shared Store

Use the same cache store:

<<< @/../lib/solid_agent/action_graph/rails_cache_adapter.rb#adapter{ruby:line-numbers}

### Cache Namespacing

Separate graph data from other cache:

<<< @/../lib/solid_agent/action_graph/namespacing.rb#namespaces{ruby:line-numbers}

## Performance

### Cache Warming

Pre-load frequently used graphs:

<<< @/../lib/solid_agent/action_graph/warming.rb#warming{ruby:line-numbers}

### Cache Stats

Monitor cache performance:

<<< @/../lib/solid_agent/action_graph/stats.rb#stats{ruby:line-numbers}

## Real-World Example

### E-commerce Agent with Cached Routing

<<< @/../test/solid_agent/examples/ecommerce_graph_test.rb#cached-routing{ruby:line-numbers}

::: details Cached Routing Output
<!-- @include: @/parts/examples/solid-agent-cached-routing.md -->
:::

## Advanced Features

### Graph Fragments

Cache partial graphs:

<<< @/../lib/solid_agent/action_graph/fragments.rb#fragments{ruby:line-numbers}

### Lazy Loading

Load graph nodes on demand:

<<< @/../lib/solid_agent/action_graph/lazy_loading.rb#lazy{ruby:line-numbers}

### Graph Compression

Compress stored graphs:

<<< @/../lib/solid_agent/action_graph/compression.rb#compression{ruby:line-numbers}

## Debugging

### Graph Inspection

Inspect cached graphs:

<<< @/../lib/solid_agent/action_graph/inspector.rb#inspection{ruby:line-numbers}

### Cache Debugging

Debug cache operations:

<<< @/../lib/solid_agent/action_graph/debug.rb#debugging{ruby:line-numbers}

## Next Steps

- [SolidCache Memory Interface](./solid-cache-memory.md)
- [Graph Store Implementations](./graph-stores.md)
- [Performance Tuning](./graph-performance.md)