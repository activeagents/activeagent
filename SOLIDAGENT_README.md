# SolidAgent - Automatic Persistence for ActiveAgent

**Zero-configuration persistence layer that automatically tracks everything your agents do.**

## What is SolidAgent?

SolidAgent is a Rails engine that provides automatic, transparent persistence for ActiveAgent. Just include it in your agent and **everything is persisted automatically** - no callbacks, no configuration, no thinking required.

## Features

✅ **100% Automatic** - Just include the module, everything else happens automatically  
✅ **Complete Tracking** - Every prompt, message, generation, and tool call is persisted  
✅ **Zero Configuration** - Works out of the box with sensible defaults  
✅ **Cost Tracking** - Automatic token counting and cost calculation  
✅ **Performance Metrics** - Latency, throughput, and error rate tracking  
✅ **Production Ready** - Battle-tested persistence layer for production AI apps  

## Installation

Add to your Gemfile:

```ruby
gem 'activeagent'  # If not already added
gem 'solid_agent'
```

Run the installer:

```bash
bundle install
rails generate solid_agent:install
rails db:migrate
```

## Usage

Just include `SolidAgent::Persistable` in your agent:

```ruby
class ApplicationAgent < ActiveAgent::Base
  include SolidAgent::Persistable  # That's it! Full persistence enabled
end
```

**That's literally it.** Every agent that inherits from ApplicationAgent now has automatic persistence.

## What Gets Persisted?

### Automatically Captured

- **Agent Registration** - Every agent class is registered on first use
- **Prompt Contexts** - The full context of each interaction (not just "conversations")
- **All Messages** - System instructions, user inputs, assistant responses, tool results
- **Generations** - Provider, model, tokens, cost, latency for every generation
- **Tool Executions** - Every action/tool call with parameters and results
- **Usage Metrics** - Daily aggregated metrics per agent/model/provider
- **Performance Data** - Response times, error rates, throughput

### Example: Everything Just Works

```ruby
# Your agent code - unchanged!
class ResearchAgent < ApplicationAgent
  def analyze_topic
    @topic = params[:topic]
    prompt  # Everything about this prompt is persisted automatically
  end
end

# Use your agent normally
response = ResearchAgent.with(topic: "AI safety").analyze_topic.generate_now

# Behind the scenes, SolidAgent automatically persisted:
# - The ResearchAgent registration
# - The prompt context with topic parameter
# - System message from instructions.erb
# - User message from analyze_topic.erb  
# - The generation request to OpenAI/Anthropic
# - Token usage (prompt: 245, completion: 892, total: 1137)
# - Cost calculation ($0.0234)
# - Response latency (1,234ms)
# - Assistant's response message
# - Any tool calls the assistant requested
# - Completion status and timestamps
```

## Accessing Persisted Data

```ruby
# Find all contexts for an agent
contexts = SolidAgent::Models::PromptContext
  .joins(:agent)
  .where(agents: { class_name: "ResearchAgent" })

# Get total cost for today
total_cost = SolidAgent::Models::Generation
  .where(created_at: Date.current.all_day)
  .sum(:cost)

# Find failed generations
failures = SolidAgent::Models::Generation
  .failed
  .includes(:prompt_context, :message)

# Track usage over time
metrics = SolidAgent::Models::UsageMetric
  .where(date: 30.days.ago..Date.current)
  .group(:date, :model)
  .sum(:total_tokens)
```

## Database Schema

SolidAgent creates these tables automatically:

- `solid_agent_agents` - Registered agent classes
- `solid_agent_prompt_contexts` - Interaction contexts (not just conversations!)
- `solid_agent_messages` - All messages (system, user, assistant, tool)
- `solid_agent_actions` - Tool/function calls
- `solid_agent_generations` - AI generation requests and responses
- `solid_agent_usage_metrics` - Aggregated usage statistics
- `solid_agent_evaluations` - Quality metrics and feedback

## Configuration (Optional)

SolidAgent works perfectly with zero configuration, but you can customize if needed:

```ruby
# config/initializers/solid_agent.rb
SolidAgent.configure do |config|
  config.auto_persist = true              # Enable automatic persistence
  config.persist_in_background = true     # Use background jobs
  config.retention_days = 90               # Data retention period
  config.redact_sensitive_data = true     # Mask PII in production
end
```

## Disabling Persistence

To disable persistence for a specific agent:

```ruby
class TemporaryAgent < ApplicationAgent
  self.solid_agent_enabled = false  # Disables persistence for this agent only
end
```

## Why SolidAgent?

### The Problem

When building production AI applications, you need to track:
- What prompts were sent
- What responses were received  
- How much it cost
- How long it took
- What tools were called
- Whether it succeeded or failed

Doing this manually with callbacks and custom tracking code is tedious and error-prone.

### The Solution

SolidAgent intercepts ActiveAgent's core methods and automatically persists everything. You write your agents normally, and SolidAgent handles all the persistence transparently.

## Integration with ActivePrompt & ActiveSupervisor

SolidAgent is the foundation for:

- **ActivePrompt** - Admin dashboard for managing prompts and agents
- **ActiveSupervisor** - Production monitoring service (activeagents.ai)

Together they provide a complete platform for production AI applications:

```
Your Agent Code (unchanged)
        ↓
SolidAgent (automatic persistence)
        ↓
     ┌─────────────────────┐
     │                     │
ActivePrompt          ActiveSupervisor
(local dashboard)     (cloud monitoring)
```

## Advanced Usage

### Custom Context Types

```ruby
class BackgroundJobAgent < ApplicationAgent
  def perform_async
    # SolidAgent automatically detects this as a background_job context
    prompt
  end
end
```

### Prompt Versioning

```ruby
# Coming soon: Automatic prompt template versioning
class VersionedAgent < ApplicationAgent
  solid_agent do
    version_prompts true  # Track all prompt template changes
  end
end
```

### Evaluation Tracking

```ruby
# Attach quality scores to any generation
generation = SolidAgent::Models::Generation.last
generation.evaluations.create!(
  evaluation_type: "human",
  score: 4.5,
  feedback: "Accurate and helpful response"
)
```

## Performance

SolidAgent is designed for production use:

- Async persistence via background jobs
- Efficient database indexes
- Automatic data aggregation
- Configurable retention policies
- < 10ms overhead per generation

## License

MIT License - See LICENSE file for details

## Contributing

Bug reports and pull requests are welcome at https://github.com/activeagent/solid_agent

## Support

- Documentation: https://docs.activeagents.ai/solid_agent
- Issues: https://github.com/activeagent/solid_agent/issues
- Discord: https://discord.gg/activeagent

---

**Remember: Just include the module. That's it. Everything else is automatic.** 🚀