# Gem Architecture

The ActiveAgent framework is composed of modular gems that work together, following the Rails pattern of separated but interdependent components.

## Core Gems

### activeagent
The main framework gem that brings everything together.

<<< @/../activeagent.gemspec#core{ruby}

Dependencies:
- `actionprompt` (required)
- `solidagent` (optional)
- `activeprompt` (optional)

### actionprompt
Message and prompt management system.

<<< @/../actionprompt/actionprompt.gemspec#core{ruby}

Provides:
- `ActionPrompt::Base` - Controller for prompts
- `ActionPrompt::Message` - Message objects
- `ActionPrompt::Prompt` - Prompt context
- `ActionPrompt::Action` - Tool definitions

### actiongraph
Graph-based routing and action management.

<<< @/../actiongraph/actiongraph.gemspec#core{ruby}

Provides:
- `ActionGraph::Graph` - Graph data structure
- `ActionGraph::Router` - Routing engine
- `ActionGraph::Cache` - Rails cache interface
- `ActionGraph::Node` - Action nodes

### solidagent
Persistence layer for agent activity.

<<< @/../solidagent/solidagent.gemspec#core{ruby}

Provides:
- `SolidAgent::Persistable` - Automatic persistence
- `SolidAgent::Memory` - Memory management
- `SolidAgent::Context` - Context tools
- `SolidAgent::Models` - ActiveRecord models

### activeprompt
Dashboard and development tools.

<<< @/../activeprompt/activeprompt.gemspec#core{ruby}

Provides:
- Rails Engine for dashboard
- Prompt engineering UI
- Testing tools
- Analytics views

## Gem Dependencies

```
activeagent (meta-gem)
├── actionprompt (required)
│   └── activesupport
├── actiongraph (optional)
│   ├── actionprompt
│   └── activesupport
├── solidagent (optional)
│   ├── actionprompt
│   ├── actiongraph
│   ├── activerecord
│   └── activejob
└── activeprompt (optional)
    ├── solidagent
    ├── actionprompt
    └── rails
```

## Installation Options

### Full Stack
Install everything:

```ruby
# Gemfile
gem 'activeagent'
```

### Core Only
Just the framework:

```ruby
# Gemfile
gem 'actionprompt'
```

### With Persistence
Add persistence layer:

```ruby
# Gemfile
gem 'actionprompt'
gem 'solidagent'
```

### With Graph Routing
Add intelligent routing:

```ruby
# Gemfile
gem 'actionprompt'
gem 'actiongraph'
```

### Dashboard
Add development tools:

```ruby
# Gemfile
gem 'activeagent'
gem 'activeprompt'
```

## Gem Structure

### actionprompt

```
actionprompt/
├── lib/
│   ├── action_prompt.rb
│   ├── action_prompt/
│   │   ├── base.rb
│   │   ├── message.rb
│   │   ├── prompt.rb
│   │   ├── action.rb
│   │   └── railtie.rb
│   └── generators/
├── app/
│   └── views/
└── actionprompt.gemspec
```

### actiongraph

```
actiongraph/
├── lib/
│   ├── action_graph.rb
│   ├── action_graph/
│   │   ├── graph.rb
│   │   ├── router.rb
│   │   ├── cache.rb
│   │   ├── node.rb
│   │   ├── edge.rb
│   │   └── railtie.rb
│   └── generators/
└── actiongraph.gemspec
```

### solidagent

```
solidagent/
├── lib/
│   ├── solid_agent.rb
│   ├── solid_agent/
│   │   ├── persistable.rb
│   │   ├── memory.rb
│   │   ├── context.rb
│   │   ├── models/
│   │   ├── engine.rb
│   │   └── railtie.rb
│   ├── generators/
│   └── tasks/
├── app/
│   └── models/
├── db/
│   └── migrate/
└── solidagent.gemspec
```

### activeprompt

```
activeprompt/
├── lib/
│   ├── active_prompt.rb
│   ├── active_prompt/
│   │   ├── engine.rb
│   │   └── version.rb
│   └── generators/
├── app/
│   ├── controllers/
│   ├── models/
│   ├── views/
│   └── assets/
├── config/
│   └── routes.rb
└── activeprompt.gemspec
```

## Configuration

### Modular Configuration

Each gem has its own configuration:

<<< @/../test/dummy/config/initializers/action_prompt.rb#config{ruby}

<<< @/../test/dummy/config/initializers/action_graph.rb#config{ruby}

<<< @/../test/dummy/config/initializers/solid_agent.rb#config{ruby}

<<< @/../test/dummy/config/initializers/active_prompt.rb#config{ruby}

### Unified Configuration

Or configure through activeagent:

<<< @/../test/dummy/config/active_agent.yml#unified{yaml}

## Version Management

### Synchronized Releases

Like Rails, major versions are synchronized:

<<< @/../lib/active_agent/version.rb#versions{ruby}

### Independent Updates

Patch versions can be released independently:
- `actionprompt 1.0.1` - Bug fix
- `solidagent 1.0.2` - Performance improvement
- `actiongraph 1.0.1` - New cache adapter

## Testing

### Gem-Specific Tests

Each gem has its own test suite:

```bash
# Test individual gems
cd actionprompt && bundle exec rake test
cd solidagent && bundle exec rake test
cd actiongraph && bundle exec rake test
cd activeprompt && bundle exec rake test
```

### Integration Tests

The main gem tests integration:

```bash
# Test full stack
bundle exec rake test:integration
```

## Development

### Working on Individual Gems

```bash
# Clone all gems
git clone https://github.com/activeagent/activeagent
git clone https://github.com/activeagent/actionprompt
git clone https://github.com/activeagent/actiongraph
git clone https://github.com/activeagent/solidagent
git clone https://github.com/activeagent/activeprompt

# Use local gems in development
# Gemfile
gem 'actionprompt', path: '../actionprompt'
gem 'actiongraph', path: '../actiongraph'
gem 'solidagent', path: '../solidagent'
```

### Contributing

Each gem accepts contributions:
- Core functionality → `actionprompt`
- Routing features → `actiongraph`
- Persistence features → `solidagent`
- Dashboard features → `activeprompt`

## Benefits of Separation

1. **Lighter deployments** - Only install what you need
2. **Independent versioning** - Update gems individually
3. **Clear boundaries** - Each gem has a specific purpose
4. **Easier testing** - Test components in isolation
5. **Flexible adoption** - Start small, add features as needed

## Migration Path

### From Monolithic activeagent

```ruby
# Old Gemfile
gem 'activeagent', '~> 0.9'

# New Gemfile (equivalent)
gem 'actionprompt', '~> 1.0'
gem 'actiongraph', '~> 1.0'
gem 'solidagent', '~> 1.0'
gem 'activeprompt', '~> 1.0'
```

### Gradual Adoption

Start with core, add features:

```ruby
# Phase 1: Core only
gem 'actionprompt'

# Phase 2: Add persistence
gem 'solid_agent'

# Phase 3: Add routing
gem 'action_graph'

# Phase 4: Add dashboard
gem 'active_prompt'
```

## Next Steps

- [ActionPrompt Documentation](../action-prompt/)
- [ActionGraph Documentation](../action-graph/)
- [SolidAgent Documentation](../solid-agent/)
- [ActivePrompt Documentation](../active-prompt/)