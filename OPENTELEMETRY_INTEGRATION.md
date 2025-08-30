# OpenTelemetry and OpenLLMetry Integration for ActiveAgent

## Overview

This document outlines the integration of OpenTelemetry and OpenLLMetry standards into ActiveAgent's observability layer, ensuring compatibility with any observability platform that supports these standards (Datadog, New Relic, Honeycomb, Splunk, Grafana, and others).

## Core Principles

1. **Standards Compliance**: Full adherence to OpenTelemetry GenAI semantic conventions and OpenLLMetry extensions
2. **Vendor Neutral**: No lock-in to specific observability platforms - works with any OTLP-compatible backend
3. **Zero-Config Default**: Works out of the box with sensible defaults and auto-discovery
4. **Phased Integration**: Telemetry grows with your gem stack (actionprompt → solid_agent → action_graph → active_prompt)
5. **Performance First**: Minimal overhead (<1% latency impact) with intelligent sampling
6. **Privacy by Design**: PII sanitization and configurable data retention

## Phased Telemetry Architecture

The telemetry system grows with your gem stack, providing appropriate observability at each level:

### Phase 1: ActionPrompt (Core)
Base telemetry for prompt engineering and LLM interactions:
- Prompt template rendering metrics
- LLM API call tracing (request/response)
- Token usage tracking
- Streaming event tracking
- Basic error and retry metrics

### Phase 2: SolidAgent (Persistence)
Adds persistence and memory telemetry:
- Conversation thread tracking
- Message persistence metrics
- Memory retrieval performance
- Context window management
- Prompt version tracking
- A/B testing metrics

### Phase 3: ActionGraph (Routing)
Adds workflow and routing telemetry:
- Agent routing decisions
- Workflow execution tracing
- Inter-agent communication
- Decision tree metrics
- Path optimization data

### Phase 4: ActivePrompt (Dashboard)
Adds comprehensive dashboard and visualization:
- Real-time metric aggregation
- Cost analysis and forecasting
- Performance dashboards
- Custom alert configuration
- Export to observability platforms

## Architecture

### 1. ActiveAgent::Telemetry Module

```ruby
module ActiveAgent
  module Telemetry
    # Core telemetry configuration
    class Configuration
      attr_accessor :enabled, :service_name, :exporter, :endpoint
      attr_accessor :sample_rate, :batch_size, :export_timeout
      attr_accessor :resource_attributes, :headers
      
      def initialize
        @enabled = ENV.fetch('ACTIVE_AGENT_TELEMETRY_ENABLED', 'true') == 'true'
        @service_name = ENV.fetch('ACTIVE_AGENT_SERVICE_NAME', 'active_agent')
        @exporter = ENV.fetch('OTEL_EXPORTER_OTLP_ENDPOINT', nil)
        @sample_rate = ENV.fetch('OTEL_TRACES_SAMPLER_ARG', '1.0').to_f
      end
    end
    
    # Automatic instrumentation
    class Instrumentor
      def self.instrument!
        return unless ActiveAgent.telemetry.enabled
        
        # Instrument all agent actions
        instrument_agents
        instrument_generations
        instrument_prompts
        instrument_tool_calls
        instrument_memory_operations if defined?(SolidAgent)
        instrument_supervisor_calls if defined?(ActiveSupervisor)
      end
    end
  end
end
```

### 2. OpenLLMetry Semantic Conventions

Following OpenLLMetry standards, we track these key attributes:

#### Span Attributes

```ruby
module ActiveAgent
  module Telemetry
    module Attributes
      # LLM-specific attributes (OpenLLMetry convention)
      LLM_REQUEST_MODEL = 'llm.request.model'
      LLM_REQUEST_TEMPERATURE = 'llm.request.temperature'
      LLM_REQUEST_MAX_TOKENS = 'llm.request.max_tokens'
      LLM_REQUEST_TOP_P = 'llm.request.top_p'
      LLM_REQUEST_STREAM = 'llm.request.stream'
      
      LLM_RESPONSE_ID = 'llm.response.id'
      LLM_RESPONSE_MODEL = 'llm.response.model'
      LLM_RESPONSE_FINISH_REASON = 'llm.response.finish_reason'
      
      LLM_USAGE_PROMPT_TOKENS = 'llm.usage.prompt_tokens'
      LLM_USAGE_COMPLETION_TOKENS = 'llm.usage.completion_tokens'
      LLM_USAGE_TOTAL_TOKENS = 'llm.usage.total_tokens'
      
      # Agent-specific attributes
      AGENT_NAME = 'agent.name'
      AGENT_ACTION = 'agent.action'
      AGENT_VERSION = 'agent.version'
      
      # Tool/Function calling attributes
      TOOL_NAME = 'tool.name'
      TOOL_PARAMETERS = 'tool.parameters'
      TOOL_RESULT = 'tool.result'
      
      # Prompt attributes
      PROMPT_TEMPLATE = 'prompt.template'
      PROMPT_VARIABLES = 'prompt.variables'
      PROMPT_MESSAGES_COUNT = 'prompt.messages.count'
      
      # Memory/Context attributes
      CONTEXT_ID = 'context.id'
      CONTEXT_WINDOW_SIZE = 'context.window.size'
      MEMORY_RETRIEVED_COUNT = 'memory.retrieved.count'
    end
  end
end
```

#### Span Events

```ruby
module ActiveAgent
  module Telemetry
    module Events
      # Track streaming chunks
      STREAM_CHUNK = 'llm.stream.chunk'
      
      # Track tool calls
      TOOL_CALLED = 'agent.tool.called'
      TOOL_COMPLETED = 'agent.tool.completed'
      TOOL_FAILED = 'agent.tool.failed'
      
      # Track memory operations
      MEMORY_STORED = 'agent.memory.stored'
      MEMORY_RETRIEVED = 'agent.memory.retrieved'
      
      # Track errors and retries
      GENERATION_RETRY = 'llm.generation.retry'
      RATE_LIMITED = 'llm.rate_limited'
    end
  end
end
```

### 3. ActivePrompt Dashboard Telemetry

The dashboard will provide real-time observability insights:

```ruby
module ActivePrompt
  class Dashboard::TelemetryController < Dashboard::BaseController
    def metrics
      @traces = fetch_recent_traces
      @metrics = aggregate_metrics
      @errors = fetch_error_traces
      
      respond_to do |format|
        format.html
        format.json { render json: @metrics }
      end
    end
    
    private
    
    def fetch_recent_traces
      # Query OpenTelemetry collector or backend
      ActiveAgent::Telemetry::Query.recent_traces(
        service: params[:service],
        agent: params[:agent],
        limit: params[:limit] || 100
      )
    end
    
    def aggregate_metrics
      {
        total_requests: count_spans('agent.action'),
        avg_latency: average_duration('agent.action'),
        token_usage: sum_attribute('llm.usage.total_tokens'),
        error_rate: error_percentage,
        top_agents: top_by_invocation_count,
        cost_estimate: estimate_costs
      }
    end
  end
end
```

### 4. ActiveSupervisor Orchestration Telemetry

Track distributed agent workflows:

```ruby
module ActiveSupervisor
  module Telemetry
    class WorkflowTracer
      def trace_workflow(workflow)
        tracer.in_span('supervisor.workflow', 
          attributes: {
            'workflow.id' => workflow.id,
            'workflow.name' => workflow.name,
            'workflow.agents_count' => workflow.agents.count
          }) do |span|
          
          # Track each agent in the workflow
          workflow.agents.each do |agent|
            trace_agent_execution(agent, span)
          end
          
          # Track orchestration decisions
          span.add_event('workflow.decision', attributes: {
            'decision.type' => workflow.decision_type,
            'decision.reason' => workflow.decision_reason
          })
        end
      end
      
      private
      
      def trace_agent_execution(agent, parent_span)
        tracer.in_span('supervisor.agent_execution',
          attributes: {
            'agent.name' => agent.class.name,
            'agent.id' => agent.id,
            'agent.priority' => agent.priority
          },
          parent: parent_span) do |span|
          
          # Track inter-agent communication
          span.add_event('agent.message_sent') if agent.sends_message?
          span.add_event('agent.message_received') if agent.receives_message?
          
          yield if block_given?
        end
      end
    end
  end
end
```

## Implementation Plan

### Phase 1: Core Instrumentation (Week 1-2)

1. **Add OpenTelemetry dependencies**
```ruby
# Gemfile
gem 'opentelemetry-sdk'
gem 'opentelemetry-exporter-otlp'
gem 'opentelemetry-instrumentation-all'
```

2. **Create base telemetry module**
```ruby
# lib/active_agent/telemetry.rb
module ActiveAgent
  module Telemetry
    class << self
      def configure
        yield configuration
        setup_tracer_provider
      end
      
      def configuration
        @configuration ||= Configuration.new
      end
      
      private
      
      def setup_tracer_provider
        OpenTelemetry::SDK.configure do |c|
          c.service_name = configuration.service_name
          c.resource = OpenTelemetry::SDK::Resources::Resource.create(
            configuration.resource_attributes
          )
          
          # Add exporters based on configuration
          if configuration.exporter
            c.add_span_processor(
              OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
                OpenTelemetry::Exporter::OTLP::Exporter.new(
                  endpoint: configuration.exporter,
                  headers: configuration.headers
                )
              )
            )
          end
        end
      end
    end
  end
end
```

### Phase 2: Agent Instrumentation (Week 2-3)

1. **Instrument agent actions**
```ruby
module ActiveAgent
  class Base
    around_action :trace_action
    
    private
    
    def trace_action
      return yield unless ActiveAgent.telemetry.enabled
      
      tracer.in_span("agent.#{action_name}",
        attributes: {
          'agent.name' => self.class.name,
          'agent.action' => action_name,
          'agent.version' => ActiveAgent::VERSION
        }) do |span|
        
        # Track parameters
        span.set_attribute('agent.parameters', params.to_json)
        
        begin
          result = yield
          span.set_status(OpenTelemetry::Trace::Status.ok)
          result
        rescue => e
          span.record_exception(e)
          span.set_status(OpenTelemetry::Trace::Status.error(e.message))
          raise
        end
      end
    end
  end
end
```

2. **Instrument generation providers**
```ruby
module ActiveAgent
  module GenerationProvider
    class Base
      def generate_with_telemetry(prompt)
        tracer.in_span('llm.generation',
          attributes: {
            LLM_REQUEST_MODEL => options[:model],
            LLM_REQUEST_TEMPERATURE => options[:temperature],
            LLM_REQUEST_MAX_TOKENS => options[:max_tokens],
            LLM_REQUEST_STREAM => options[:stream]
          }) do |span|
          
          response = perform_generation(prompt)
          
          # Track token usage
          span.set_attribute(LLM_USAGE_PROMPT_TOKENS, response.prompt_tokens)
          span.set_attribute(LLM_USAGE_COMPLETION_TOKENS, response.completion_tokens)
          span.set_attribute(LLM_USAGE_TOTAL_TOKENS, response.total_tokens)
          
          # Track response metadata
          span.set_attribute(LLM_RESPONSE_ID, response.id)
          span.set_attribute(LLM_RESPONSE_MODEL, response.model)
          span.set_attribute(LLM_RESPONSE_FINISH_REASON, response.finish_reason)
          
          response
        end
      end
    end
  end
end
```

### Phase 3: Dashboard Integration (Week 3-4)

1. **Add telemetry views to ActivePrompt**
```ruby
# app/views/active_prompt/dashboard/telemetry/index.html.erb
<div class="telemetry-dashboard">
  <div class="metrics-grid">
    <div class="metric-card">
      <h3>Total Generations</h3>
      <div class="metric-value"><%= @metrics[:total_requests] %></div>
    </div>
    
    <div class="metric-card">
      <h3>Avg Latency</h3>
      <div class="metric-value"><%= @metrics[:avg_latency] %>ms</div>
    </div>
    
    <div class="metric-card">
      <h3>Token Usage</h3>
      <div class="metric-value"><%= number_with_delimiter(@metrics[:token_usage]) %></div>
    </div>
    
    <div class="metric-card">
      <h3>Error Rate</h3>
      <div class="metric-value"><%= @metrics[:error_rate] %>%</div>
    </div>
  </div>
  
  <div class="trace-explorer">
    <h2>Recent Traces</h2>
    <%= render partial: 'trace', collection: @traces %>
  </div>
</div>
```

2. **Add real-time monitoring WebSocket**
```ruby
module ActivePrompt
  class TelemetryChannel < ActionCable::Channel
    def subscribed
      stream_from "telemetry:#{params[:agent_id]}"
    end
    
    def unsubscribed
      stop_all_streams
    end
  end
end
```

### Phase 4: Supervisor Integration (Week 4-5)

1. **Track distributed workflows**
```ruby
module ActiveSupervisor
  class Workflow
    include ActiveAgent::Telemetry::Traceable
    
    def execute
      trace_workflow do
        # Create parent span for the entire workflow
        tracer.in_span('supervisor.workflow.execute') do |workflow_span|
          workflow_span.set_attribute('workflow.id', id)
          workflow_span.set_attribute('workflow.name', name)
          
          # Track each step with linked spans
          steps.each do |step|
            execute_step(step, workflow_span)
          end
        end
      end
    end
    
    private
    
    def execute_step(step, parent_span)
      # Create linked span for distributed tracing
      links = [OpenTelemetry::Trace::Link.new(parent_span.context)]
      
      tracer.in_span('supervisor.step.execute', links: links) do |span|
        span.set_attribute('step.name', step.name)
        span.set_attribute('step.agent', step.agent_class.name)
        
        step.execute
      end
    end
  end
end
```

## Configuration Examples

### Basic Configuration

```yaml
# config/active_agent.yml
default: &default
  telemetry:
    enabled: true
    service_name: my_app_agents
    sample_rate: 1.0
    
development:
  <<: *default
  telemetry:
    exporter: console  # Logs to console in development
    
production:
  <<: *default
  telemetry:
    exporter: <%= ENV['OTEL_EXPORTER_OTLP_ENDPOINT'] %>
    headers:
      api-key: <%= ENV['OTEL_EXPORTER_API_KEY'] %>
    sample_rate: 0.1  # Sample 10% in production
```

### Datadog Integration

```ruby
# config/initializers/active_agent_telemetry.rb
ActiveAgent::Telemetry.configure do |config|
  config.enabled = true
  config.service_name = 'my-app-agents'
  config.exporter = 'https://trace.agent.datadoghq.com:4318/v1/traces'
  config.headers = {
    'DD-API-KEY' => ENV['DD_API_KEY']
  }
  config.resource_attributes = {
    'service.name' => 'my-app-agents',
    'service.version' => MyApp::VERSION,
    'deployment.environment' => Rails.env
  }
end
```

### New Relic Integration

```ruby
# config/initializers/active_agent_telemetry.rb
ActiveAgent::Telemetry.configure do |config|
  config.enabled = true
  config.service_name = 'my-app-agents'
  config.exporter = "https://otlp.nr-data.net:4318/v1/traces"
  config.headers = {
    'api-key' => ENV['NEW_RELIC_LICENSE_KEY']
  }
end
```

### Honeycomb Integration

```ruby
# config/initializers/active_agent_telemetry.rb
ActiveAgent::Telemetry.configure do |config|
  config.enabled = true
  config.service_name = 'my-app-agents'
  config.exporter = 'https://api.honeycomb.io:443'
  config.headers = {
    'x-honeycomb-team' => ENV['HONEYCOMB_API_KEY'],
    'x-honeycomb-dataset' => 'active-agents'
  }
end
```

## Testing Strategy

### Unit Tests

```ruby
# test/telemetry/instrumentation_test.rb
class TelemetryInstrumentationTest < ActiveSupport::TestCase
  setup do
    @exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    ActiveAgent::Telemetry.configure do |config|
      config.enabled = true
      config.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter)
      )
    end
  end
  
  test "traces agent action execution" do
    agent = TestAgent.new
    agent.test_action
    
    spans = @exporter.finished_spans
    assert_equal 1, spans.length
    
    span = spans.first
    assert_equal 'agent.test_action', span.name
    assert_equal 'TestAgent', span.attributes['agent.name']
  end
  
  test "tracks LLM token usage" do
    response = TestAgent.new.generate(prompt: "Test")
    
    spans = @exporter.finished_spans
    llm_span = spans.find { |s| s.name == 'llm.generation' }
    
    assert llm_span.attributes['llm.usage.total_tokens'] > 0
    assert llm_span.attributes['llm.response.model'].present?
  end
end
```

### Integration Tests

```ruby
# test/integration/telemetry_integration_test.rb
class TelemetryIntegrationTest < ActionDispatch::IntegrationTest
  test "end-to-end tracing through dashboard" do
    # Enable test exporter
    setup_test_telemetry
    
    # Make request through dashboard
    post '/active_prompt/agents/support_agent/generate',
      params: { prompt: "Help me" }
    
    # Verify trace propagation
    assert_spans_include [
      'http.request',
      'agent.support_agent',
      'llm.generation',
      'tool.search_knowledge_base'
    ]
  end
end
```

## Monitoring Best Practices

1. **Sampling Strategy**
   - Development: 100% sampling
   - Staging: 10-50% sampling
   - Production: 1-10% sampling (adjust based on volume)

2. **Cost Management**
   - Use head-based sampling for high-volume agents
   - Implement tail-based sampling for error traces
   - Set up alerts for unusual token usage

3. **Privacy & Security**
   - Never log PII in span attributes
   - Sanitize prompt content before sending to telemetry
   - Use secure transport (HTTPS/TLS) for exporters

4. **Performance**
   - Use batch exporters to reduce overhead
   - Implement circuit breakers for telemetry endpoints
   - Monitor telemetry overhead (should be <1% of response time)

## Migration Path

For existing ActiveAgent users:

1. **Version 1.0**: Telemetry disabled by default
2. **Version 1.1**: Telemetry enabled in development only
3. **Version 2.0**: Telemetry enabled by default with console exporter
4. **Version 2.1**: Full OpenLLMetry semantic convention support

## Resources

- [OpenTelemetry Ruby](https://opentelemetry.io/docs/instrumentation/ruby/)
- [OpenLLMetry GitHub](https://github.com/traceloop/openllmetry)
- [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [OTLP Specification](https://opentelemetry.io/docs/specs/otlp/)