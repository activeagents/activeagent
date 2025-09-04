# The Complete ActiveAgent Platform

The ActiveAgent ecosystem provides a comprehensive platform for building, deploying, and monitoring production AI applications.

## Three-Layer Architecture

### Layer 1: ActiveAgent Core
The foundation - Rails-based agent framework.

<<< @/../lib/active_agent/base.rb#solid-agent-integration{ruby:line-numbers}

### Layer 2: SolidAgent Persistence
Automatic, zero-configuration persistence.

<<< @/../lib/solid_agent/persistable.rb#module-definition{ruby:line-numbers}

### Layer 3: ActiveSupervisor Monitoring
Cloud SaaS or self-hosted monitoring platform.

<<< @/../lib/active_supervisor_client/trackable.rb#trackable-module{ruby:line-numbers}

## How They Work Together

### Automatic Integration

When all three components are installed:

<<< @/../test/solid_agent/integration_test.rb#complete-integration{ruby:line-numbers}

::: details Integration Example Output
<!-- @include: @/parts/examples/complete-integration-output.md -->
:::

## Deployment Models

### Cloud SaaS

<<< @/../test/dummy/config/active_supervisor.yml#cloud-config{yaml}

### Self-Hosted

<<< @/../test/dummy/config/active_supervisor.yml#self-hosted-config{yaml}

## Data Flow

The complete data flow from agent to monitoring:

<<< @/../test/solid_agent/data_flow_test.rb#data-flow{ruby:line-numbers}

::: details Data Flow Visualization
<!-- @include: @/parts/examples/data-flow-diagram.md -->
:::

## Production Architecture

### High-Level Overview

```
┌──────────────────────────────────────────────────────┐
│                   Your Rails App                      │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │              ApplicationAgent                    │ │
│  │                                                  │ │
│  │  ┌──────────────┐  ┌──────────────────────┐   │ │
│  │  │ ActiveAgent  │  │   SolidAgent         │   │ │
│  │  │    Core      │  │   (Persistence)      │   │ │
│  │  └──────────────┘  └──────────────────────┘   │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
                           │
                           │ Events
                           ↓
        ┌──────────────────────────────────────┐
        │         ActiveSupervisor              │
        │    (Cloud or Self-Hosted)            │
        │                                       │
        │  ┌──────────┐  ┌──────────────┐     │
        │  │ Analytics│  │  Dashboard   │     │
        │  └──────────┘  └──────────────┘     │
        └──────────────────────────────────────┘
```

### Database Architecture

<<< @/../docs/solid_agent_db_architecture.sql#architecture{sql:line-numbers}

## Key Benefits

### For Developers

1. **Zero Configuration** - Just include the modules
2. **Automatic Everything** - No callbacks needed
3. **Complete Tracking** - Every aspect captured
4. **Flexible Deployment** - Cloud or self-hosted

### For Operations

1. **Real-time Monitoring** - Live dashboards
2. **Cost Control** - Token and pricing tracking
3. **Performance Insights** - Latency and throughput
4. **Anomaly Detection** - ML-powered alerts

### For Business

1. **ROI Tracking** - Cost per outcome
2. **User Analytics** - Engagement metrics
3. **Quality Metrics** - Satisfaction scores
4. **Compliance** - Audit trails and GDPR

## Getting Started

### Quick Start (Cloud)

<<< @/../test/solid_agent/quickstart.rb#cloud-quickstart{ruby:line-numbers}

### Quick Start (Self-Hosted)

<<< @/../test/solid_agent/quickstart.rb#self-hosted-quickstart{ruby:line-numbers}

## Example: Complete Agent with Monitoring

<<< @/../test/dummy/app/agents/monitored_agent.rb#complete-agent{ruby:line-numbers}

::: details Agent Execution Output
<!-- @include: @/parts/examples/monitored-agent-output.md -->
:::

## Comparison with Alternatives

| Feature | ActiveAgent Platform | LangChain + DataDog | Custom Solution |
|---------|---------------------|---------------------|-----------------|
| Rails Native | ✅ | ❌ | ❓ |
| Zero Config | ✅ | ❌ | ❌ |
| Automatic Persistence | ✅ | ❌ | ❓ |
| AI-Specific Monitoring | ✅ | Partial | ❓ |
| Self-Hosted Option | ✅ | ❌ | ✅ |
| Vector Search | ✅ | ❌ | ❓ |
| Cost Tracking | ✅ | ❌ | ❓ |
| Open Source | ✅ | Partial | ✅ |

## Resources

- [GitHub Repository](https://github.com/activeagent/activeagent)
- [Documentation](https://docs.activeagents.ai)
- [Cloud Platform](https://activeagents.ai)
- [Discord Community](https://discord.gg/activeagent)