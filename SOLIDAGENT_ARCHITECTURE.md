# SolidAgent Architecture - ActiveAgent Persistence & Monitoring

## Overview

This document outlines the architecture for three complementary Rails engines that work together to provide persistence, management, and monitoring capabilities for ActiveAgent:

1. **SolidAgent** - ActiveRecord persistence layer for agents, prompts, and conversations
2. **ActivePrompt** - Admin dashboard and prompt engineering tools
3. **ActiveSupervisor** - Production monitoring and analytics service (activeagents.ai)

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    ActiveSupervisor Service                     │
│              (activeagents.ai - SaaS Monitoring)            │
├─────────────────────────────────────────────────────────────┤
│                    ActivePrompt Engine                       │
│           (Admin Dashboard & Prompt Engineering)             │
├─────────────────────────────────────────────────────────────┤
│                     SolidAgent Engine                        │
│         (ActiveRecord Models & Persistence Layer)            │
├─────────────────────────────────────────────────────────────┤
│                      ActiveAgent Core                        │
│              (Agent Framework & Generation)                  │
└─────────────────────────────────────────────────────────────┘
```

## 1. SolidAgent Engine - Persistence Layer

### Purpose
Provides ActiveRecord models and persistence for ActiveAgent objects, enabling:
- Conversation history tracking
- Prompt version control
- Cost and usage analytics
- Evaluation and feedback storage
- Agent configuration management

### Core Models

#### Agent Management
- `SolidAgent::Agent` - Registered agent classes and their metadata
- `SolidAgent::AgentConfig` - Runtime configurations per agent
- `SolidAgent::AgentVersion` - Version tracking for agent implementations

#### Prompt Engineering
- `SolidAgent::Prompt` - Prompt templates with versioning
- `SolidAgent::PromptVersion` - Historical prompt versions
- `SolidAgent::PromptVariant` - A/B testing variants
- `SolidAgent::PromptEvaluation` - Quality metrics per prompt

#### Conversation Management
- `SolidAgent::Conversation` - Conversation threads
- `SolidAgent::Message` - Individual messages in conversations
- `SolidAgent::Action` - Tool/function calls requested
- `SolidAgent::ActionResult` - Results from executed actions

#### Generation Tracking
- `SolidAgent::Generation` - Individual generation requests
- `SolidAgent::GenerationMetrics` - Performance and cost data
- `SolidAgent::GenerationError` - Error tracking and debugging

#### Analytics
- `SolidAgent::UsageMetric` - Token usage and costs
- `SolidAgent::PerformanceMetric` - Latency and throughput
- `SolidAgent::Evaluation` - Human and automated evaluations

### Integration with ActiveAgent

```ruby
# Automatic persistence via callbacks
class CustomerSupportAgent < ApplicationAgent
  include SolidAgent::Persistable
  
  solid_agent do
    track_conversations true
    store_generations true
    version_prompts true
    enable_evaluations true
  end
end
```

### Key Features
- Automatic conversation persistence
- Prompt version control with rollback
- Cost tracking per generation
- Performance metrics collection
- Evaluation and feedback loops

## 2. ActivePrompt Engine - Admin Dashboard

### Purpose
Provides a web UI for managing agents, prompts, and conversations in development and production environments.

### Core Components

#### Controllers
- `ActivePrompt::AgentsController` - Agent discovery and management
- `ActivePrompt::PromptsController` - Prompt editing and versioning
- `ActivePrompt::ConversationsController` - Conversation browsing
- `ActivePrompt::EvaluationsController` - Quality assessment
- `ActivePrompt::AnalyticsController` - Usage and cost analytics

#### Features

##### Agent Management
- Auto-discover agents in Rails app
- View agent schemas and actions
- Test agents with live preview
- Configure agent settings

##### Prompt Engineering
- Visual prompt editor with syntax highlighting
- Template variable management
- Version history and diff view
- A/B testing configuration
- Rollback to previous versions

##### Conversation Browser
- Search and filter conversations
- Replay conversation flows
- Export conversation data
- Debug tool call sequences

##### Analytics Dashboard
- Token usage charts
- Cost breakdown by agent/model
- Response time metrics
- Error rate monitoring
- Evaluation scores

### Mounting in Rails App

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount ActivePrompt::Engine => '/admin/agents'
end
```

## 3. ActiveSupervisor Service - Production Monitoring

### Purpose
Cloud-based monitoring service (activeagents.ai) that provides:
- Real-time agent monitoring
- Cross-application analytics
- Alerting and notifications
- Team collaboration features

### Architecture

```
┌──────────────────────────────────────────┐
│         ActiveSupervisor Cloud              │
│                                          │
│  ┌────────────┐  ┌──────────────────┐  │
│  │ Ingestion  │  │   Time Series    │  │
│  │   API      │  │    Database      │  │
│  └────────────┘  └──────────────────┘  │
│                                          │
│  ┌────────────┐  ┌──────────────────┐  │
│  │ Analytics  │  │   Alerting       │  │
│  │  Engine    │  │    Engine        │  │
│  └────────────┘  └──────────────────┘  │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │      Web Dashboard & API           │ │
│  └────────────────────────────────────┘ │
└──────────────────────────────────────────┘
                    ↑
                    │ HTTPS/WebSocket
                    │
┌──────────────────────────────────────────┐
│          Client Applications             │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │    SolidAgent::Monitor Client      │ │
│  │         (Ruby Gem)                 │ │
│  └────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

### Client Integration

```ruby
# Gemfile
gem 'solid_agent'
gem 'active_monitor_client'

# config/initializers/active_monitor.rb
ActiveSupervisor.configure do |config|
  config.api_key = Rails.credentials.active_monitor_api_key
  config.environment = Rails.env
  config.application_name = "MyApp"
end

# Automatic monitoring
class ApplicationAgent < ActiveAgent::Base
  include SolidAgent::Persistable
  include ActiveSupervisor::Trackable
end
```

### Core Features

#### Real-time Monitoring
- Live generation tracking
- Streaming response monitoring
- Error detection and alerting
- Performance anomaly detection

#### Analytics Platform
- Cross-application metrics
- Model performance comparison
- Cost optimization insights
- Usage pattern analysis

#### Team Collaboration
- Shared dashboards
- Team-based access control
- Annotation and comments
- Alert routing

#### Integration Ecosystem
- Slack/Teams notifications
- PagerDuty integration
- Datadog/New Relic export
- Webhook notifications

## Data Flow Architecture

```
1. Agent Generation Request
   ↓
2. ActiveAgent processes request
   ↓
3. SolidAgent persists to database
   ↓
4. ActiveSupervisor client sends metrics
   ↓
5. ActiveSupervisor aggregates data
   ↓
6. ActivePrompt displays local data
   ↓
7. ActiveSupervisor shows global metrics
```

## Database Schema Design

### SolidAgent Core Tables

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

-- Prompt templates with versioning
CREATE TABLE solid_agent_prompts (
  id BIGSERIAL PRIMARY KEY,
  agent_id BIGINT REFERENCES solid_agent_agents(id),
  action_name VARCHAR NOT NULL,
  current_version_id BIGINT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  INDEX idx_agent_action (agent_id, action_name)
);

-- Prompt versions
CREATE TABLE solid_agent_prompt_versions (
  id BIGSERIAL PRIMARY KEY,
  prompt_id BIGINT REFERENCES solid_agent_prompts(id),
  version_number INTEGER NOT NULL,
  template_content TEXT,
  instructions TEXT,
  schema_definition JSONB,
  active BOOLEAN DEFAULT false,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL,
  UNIQUE INDEX idx_prompt_version (prompt_id, version_number)
);

-- Conversations
CREATE TABLE solid_agent_conversations (
  id BIGSERIAL PRIMARY KEY,
  agent_id BIGINT REFERENCES solid_agent_agents(id),
  external_id VARCHAR UNIQUE,
  user_id BIGINT,
  user_type VARCHAR,
  status VARCHAR DEFAULT 'active',
  started_at TIMESTAMP NOT NULL,
  ended_at TIMESTAMP,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  INDEX idx_user (user_type, user_id),
  INDEX idx_status_time (status, started_at)
);

-- Messages
CREATE TABLE solid_agent_messages (
  id BIGSERIAL PRIMARY KEY,
  conversation_id BIGINT REFERENCES solid_agent_conversations(id),
  role VARCHAR NOT NULL, -- system, user, assistant, tool
  content TEXT,
  content_type VARCHAR DEFAULT 'text',
  position INTEGER NOT NULL,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL,
  INDEX idx_conversation_position (conversation_id, position)
);

-- Actions (tool calls)
CREATE TABLE solid_agent_actions (
  id BIGSERIAL PRIMARY KEY,
  message_id BIGINT REFERENCES solid_agent_messages(id),
  action_name VARCHAR NOT NULL,
  action_id VARCHAR UNIQUE,
  parameters JSONB,
  status VARCHAR DEFAULT 'pending',
  executed_at TIMESTAMP,
  result_message_id BIGINT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL,
  INDEX idx_message_actions (message_id),
  INDEX idx_action_id (action_id)
);

-- Generations
CREATE TABLE solid_agent_generations (
  id BIGSERIAL PRIMARY KEY,
  conversation_id BIGINT REFERENCES solid_agent_conversations(id),
  message_id BIGINT REFERENCES solid_agent_messages(id),
  prompt_version_id BIGINT REFERENCES solid_agent_prompt_versions(id),
  provider VARCHAR NOT NULL,
  model VARCHAR NOT NULL,
  prompt_tokens INTEGER,
  completion_tokens INTEGER,
  total_tokens INTEGER,
  cost DECIMAL(10,6),
  latency_ms INTEGER,
  status VARCHAR DEFAULT 'pending',
  error_message TEXT,
  options JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL,
  completed_at TIMESTAMP,
  INDEX idx_conversation_generations (conversation_id),
  INDEX idx_provider_model (provider, model),
  INDEX idx_status_time (status, created_at)
);

-- Evaluations
CREATE TABLE solid_agent_evaluations (
  id BIGSERIAL PRIMARY KEY,
  evaluatable_type VARCHAR NOT NULL,
  evaluatable_id BIGINT NOT NULL,
  evaluation_type VARCHAR NOT NULL, -- human, automated, hybrid
  score DECIMAL(5,2),
  feedback TEXT,
  metrics JSONB DEFAULT '{}',
  evaluator_id BIGINT,
  evaluator_type VARCHAR,
  created_at TIMESTAMP NOT NULL,
  INDEX idx_evaluatable (evaluatable_type, evaluatable_id),
  INDEX idx_type_score (evaluation_type, score)
);

-- Usage metrics
CREATE TABLE solid_agent_usage_metrics (
  id BIGSERIAL PRIMARY KEY,
  agent_id BIGINT REFERENCES solid_agent_agents(id),
  date DATE NOT NULL,
  provider VARCHAR NOT NULL,
  model VARCHAR NOT NULL,
  total_requests INTEGER DEFAULT 0,
  total_tokens INTEGER DEFAULT 0,
  total_cost DECIMAL(10,2) DEFAULT 0,
  error_count INTEGER DEFAULT 0,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  UNIQUE INDEX idx_agent_date_provider (agent_id, date, provider, model)
);
```

## Implementation Phases

### Phase 1: SolidAgent Foundation (Weeks 1-3)
- [ ] Create SolidAgent Rails engine structure
- [ ] Implement core ActiveRecord models
- [ ] Add persistence hooks to ActiveAgent
- [ ] Create migration generators
- [ ] Write comprehensive tests

### Phase 2: ActiveAgent Integration (Week 4)
- [ ] Implement SolidAgent::Persistable concern
- [ ] Add configuration DSL
- [ ] Create background job processors
- [ ] Add transaction support
- [ ] Performance optimization

### Phase 3: ActivePrompt Dashboard (Weeks 5-7)
- [ ] Build Rails engine structure
- [ ] Implement admin controllers
- [ ] Create dashboard views (using ViewComponent)
- [ ] Add real-time updates (Turbo/Stimulus)
- [ ] Build prompt editor interface

### Phase 4: ActiveSupervisor MVP (Weeks 8-10)
- [ ] Set up cloud infrastructure
- [ ] Build ingestion API
- [ ] Implement time-series storage
- [ ] Create analytics engine
- [ ] Build web dashboard

### Phase 5: Integration & Testing (Weeks 11-12)
- [ ] End-to-end testing
- [ ] Performance testing
- [ ] Documentation
- [ ] Beta release

## Configuration Examples

### SolidAgent Configuration

```ruby
# config/initializers/solid_agent.rb
SolidAgent.configure do |config|
  # Persistence settings
  config.auto_persist = true
  config.persist_in_background = true
  config.retention_days = 90
  
  # Performance settings
  config.batch_size = 100
  config.async_processor = :sidekiq
  
  # Privacy settings
  config.redact_sensitive_data = true
  config.encryption_key = Rails.credentials.solid_agent_encryption_key
end
```

### ActivePrompt Configuration

```ruby
# config/initializers/active_prompt.rb
ActivePrompt.configure do |config|
  # Authentication
  config.authentication_method = :devise
  config.authorize_with do
    redirect_to '/' unless current_user&.admin?
  end
  
  # UI settings
  config.theme = :light
  config.enable_code_editor = true
  config.syntax_highlighting = true
end
```

### ActiveSupervisor Configuration

```ruby
# config/initializers/active_monitor.rb
ActiveSupervisor.configure do |config|
  # Connection settings
  config.api_endpoint = 'https://api.activeagents.ai'
  config.api_key = Rails.credentials.active_monitor_api_key
  
  # Monitoring settings
  config.sample_rate = 1.0  # 100% sampling
  config.batch_interval = 60  # seconds
  config.enable_profiling = Rails.env.production?
  
  # Alerting
  config.alert_channels = [:email, :slack]
  config.alert_thresholds = {
    error_rate: 0.05,
    response_time_p95: 5000,  # ms
    cost_per_hour: 100.00
  }
end
```

## Security Considerations

### Data Privacy
- PII redaction in logs and metrics
- Encryption at rest and in transit
- GDPR compliance features
- Data retention policies

### Access Control
- Role-based access (RBAC)
- API key management
- Audit logging
- IP allowlisting

### Multi-tenancy
- Workspace isolation
- Cross-tenant data protection
- Resource quotas
- Usage limits

## Performance Optimization

### Database
- Proper indexing strategy
- Partitioning for time-series data
- Connection pooling
- Read replicas for analytics

### Caching
- Redis for hot data
- CDN for dashboard assets
- Query result caching
- Prompt template caching

### Background Processing
- Sidekiq for async jobs
- Batch processing for metrics
- Stream processing for real-time data
- Rate limiting for API calls

## Monitoring & Observability

### Metrics
- Application performance (APM)
- Database query performance
- Background job metrics
- API endpoint monitoring

### Logging
- Structured logging (JSON)
- Centralized log aggregation
- Error tracking (Sentry)
- Audit trails

### Alerting
- Threshold-based alerts
- Anomaly detection
- Escalation policies
- Alert fatigue prevention

## Success Metrics

### Technical KPIs
- 99.9% uptime SLA
- < 100ms p50 response time
- < 500ms p95 response time
- < 0.1% error rate

### Business KPIs
- User adoption rate
- Prompt optimization impact
- Cost reduction achieved
- Developer productivity gains

### Feature Adoption
- Active users per month
- Prompts created/edited
- Evaluations performed
- Alerts configured

## Future Enhancements

### Near-term (3-6 months)
- Prompt marketplace
- Team collaboration features
- Advanced A/B testing
- Custom evaluation metrics

### Mid-term (6-12 months)
- Multi-model orchestration
- Prompt chains and workflows
- Advanced cost optimization
- Compliance reporting

### Long-term (12+ months)
- AI-powered prompt optimization
- Predictive analytics
- Cross-platform SDK
- Enterprise features