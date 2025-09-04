# ActiveAgent Upgrade Plan: SolidAgent & ActionPrompt Studio

## Executive Summary

This document outlines the upgrade path for ActiveAgent to include:
1. **SolidAgent** - ActiveRecord-based persistence layer for production AI applications
2. **ActionPrompt Studio** - Electron-based development tool (Postman for AI agents)
3. **ActiveAgent Dashboard** - Rails Engine for production monitoring and management

## Current State Analysis

### Existing ActionPrompt Implementation

ActionPrompt currently provides:
- **Core Classes**:
  - `ActionPrompt::Base` - Controller-like base for prompt handling
  - `ActionPrompt::Prompt` - Context object for prompt data
  - `ActionPrompt::Message` - Message representation with roles
  - `ActionPrompt::Action` - Tool call representation

- **Features**:
  - Rails view integration for prompt rendering
  - Multimodal content support
  - Tool/function calling
  - Streaming capabilities
  - Observer/Interceptor pattern

### Gap Analysis

Missing components for production use:
1. No persistence layer for prompts/conversations
2. No version control for prompt templates
3. No cost tracking or usage analytics
4. No evaluation/feedback system
5. No visual development tools
6. No production monitoring dashboard

## Phase 1: SolidAgent Implementation

### 1.1 Database Schema Design

```ruby
# Migration: create_solid_agent_tables.rb
class CreateSolidAgentTables < ActiveRecord::Migration[7.1]
  def change
    # Prompt version control
    create_table :solid_agent_prompts do |t|
      t.string :agent_class, null: false
      t.string :action_name, null: false
      t.text :template_content
      t.string :version, null: false
      t.boolean :active, default: false
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index [:agent_class, :action_name, :active]
      t.index [:agent_class, :action_name, :version], unique: true
    end
    
    # Conversation tracking
    create_table :solid_agent_conversations do |t|
      t.string :agent_class
      t.string :context_id
      t.references :user, polymorphic: true
      t.string :status # active, completed, failed
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index :context_id, unique: true
      t.index [:user_type, :user_id]
    end
    
    # Message persistence
    create_table :solid_agent_messages do |t|
      t.references :conversation, null: false
      t.string :role # system, user, assistant, tool
      t.text :content
      t.string :action_id
      t.string :action_name
      t.jsonb :requested_actions, default: []
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index :conversation_id
      t.index :action_id
    end
    
    # Generation tracking
    create_table :solid_agent_generations do |t|
      t.references :conversation
      t.references :message
      t.string :provider
      t.string :model
      t.integer :prompt_tokens
      t.integer :completion_tokens
      t.decimal :cost, precision: 10, scale: 6
      t.integer :latency_ms
      t.jsonb :options, default: {}
      t.timestamps
      
      t.index :conversation_id
      t.index [:provider, :model]
    end
    
    # Evaluation and feedback
    create_table :solid_agent_evaluations do |t|
      t.references :conversation
      t.references :message
      t.references :generation
      t.string :evaluation_type # human, automated, hybrid
      t.decimal :score, precision: 5, scale: 2
      t.text :feedback
      t.jsonb :metrics, default: {}
      t.references :evaluator, polymorphic: true
      t.timestamps
      
      t.index [:conversation_id, :evaluation_type]
    end
    
    # Agent configurations
    create_table :solid_agent_configs do |t|
      t.string :agent_class, null: false
      t.string :environment # development, staging, production
      t.jsonb :provider_settings, default: {}
      t.jsonb :default_options, default: {}
      t.boolean :tracking_enabled, default: true
      t.boolean :evaluation_enabled, default: false
      t.timestamps
      
      t.index [:agent_class, :environment], unique: true
    end
  end
end
```

### 1.2 Model Implementation

```ruby
# lib/solid_agent/models/prompt.rb
module SolidAgent
  class Prompt < ActiveRecord::Base
    self.table_name = 'solid_agent_prompts'
    
    validates :agent_class, :action_name, :version, presence: true
    validates :version, uniqueness: { scope: [:agent_class, :action_name] }
    
    scope :active, -> { where(active: true) }
    scope :for_agent, ->(klass) { where(agent_class: klass) }
    
    def activate!
      transaction do
        self.class.where(agent_class: agent_class, action_name: action_name)
                  .update_all(active: false)
        update!(active: true)
      end
    end
    
    def rollback_to!
      activate!
    end
  end
  
  class Conversation < ActiveRecord::Base
    self.table_name = 'solid_agent_conversations'
    
    has_many :messages, dependent: :destroy
    has_many :generations, dependent: :destroy
    has_many :evaluations, dependent: :destroy
    belongs_to :user, polymorphic: true, optional: true
    
    scope :active, -> { where(status: 'active') }
    scope :completed, -> { where(status: 'completed') }
    
    def total_cost
      generations.sum(:cost)
    end
    
    def total_tokens
      generations.sum(:prompt_tokens) + generations.sum(:completion_tokens)
    end
  end
  
  class Message < ActiveRecord::Base
    self.table_name = 'solid_agent_messages'
    
    belongs_to :conversation
    has_one :generation, dependent: :destroy
    has_many :evaluations, dependent: :destroy
    
    validates :role, inclusion: { in: %w[system user assistant tool] }
    
    def to_action_prompt_message
      ActiveAgent::ActionPrompt::Message.new(
        role: role.to_sym,
        content: content,
        action_id: action_id,
        action_name: action_name,
        requested_actions: requested_actions
      )
    end
  end
end
```

### 1.3 ActiveAgent Integration

```ruby
# lib/solid_agent/agent_extensions.rb
module SolidAgent
  module AgentExtensions
    extend ActiveSupport::Concern
    
    included do
      class_attribute :solid_agent_config
      after_action :persist_conversation, if: :tracking_enabled?
    end
    
    class_methods do
      def solid_agent(&block)
        self.solid_agent_config = Config.new
        self.solid_agent_config.instance_eval(&block)
      end
    end
    
    private
    
    def tracking_enabled?
      solid_agent_config&.tracking_enabled
    end
    
    def persist_conversation
      return unless context.present?
      
      SolidAgent::ConversationPersister.new(
        agent: self,
        context: context,
        response: response
      ).persist!
    end
  end
end

# Auto-include in ActiveAgent::Base
ActiveAgent::Base.include(SolidAgent::AgentExtensions)
```

## Phase 2: Rails Engine Dashboard

### 2.1 Engine Structure

```ruby
# solid_agent_dashboard/lib/solid_agent_dashboard/engine.rb
module SolidAgentDashboard
  class Engine < ::Rails::Engine
    isolate_namespace SolidAgentDashboard
    
    config.generators do |g|
      g.test_framework :rspec
      g.fixture_replacement :factory_bot
      g.factory_bot dir: 'spec/factories'
    end
    
    initializer "solid_agent_dashboard.assets" do |app|
      app.config.assets.precompile += %w(
        solid_agent_dashboard/application.css
        solid_agent_dashboard/application.js
      )
    end
  end
end
```

### 2.2 Dashboard Controllers

```ruby
# solid_agent_dashboard/app/controllers/solid_agent_dashboard/agents_controller.rb
module SolidAgentDashboard
  class AgentsController < ApplicationController
    def index
      @agents = discover_agents
      @stats = calculate_agent_stats
    end
    
    def show
      @agent_class = params[:id].constantize
      @conversations = SolidAgent::Conversation
                        .where(agent_class: params[:id])
                        .includes(:messages, :generations)
                        .page(params[:page])
    end
    
    def test
      @agent_class = params[:id].constantize
      @agent = @agent_class.new
    end
    
    private
    
    def discover_agents
      Rails.application.eager_load!
      ActiveAgent::Base.descendants.map do |klass|
        {
          name: klass.name,
          actions: klass.action_methods,
          provider: klass.generation_provider,
          stats: agent_stats(klass)
        }
      end
    end
  end
end
```

### 2.3 Dashboard Views

```erb
<!-- solid_agent_dashboard/app/views/solid_agent_dashboard/agents/index.html.erb -->
<div class="dashboard-container">
  <h1>ActiveAgent Dashboard</h1>
  
  <div class="stats-grid">
    <div class="stat-card">
      <h3>Total Agents</h3>
      <p><%= @agents.count %></p>
    </div>
    <div class="stat-card">
      <h3>Total Conversations</h3>
      <p><%= @stats[:total_conversations] %></p>
    </div>
    <div class="stat-card">
      <h3>Total Cost</h3>
      <p>$<%= @stats[:total_cost] %></p>
    </div>
  </div>
  
  <div class="agents-list">
    <% @agents.each do |agent| %>
      <div class="agent-card">
        <h3><%= link_to agent[:name], agent_path(agent[:name]) %></h3>
        <p>Provider: <%= agent[:provider] %></p>
        <p>Actions: <%= agent[:actions].join(", ") %></p>
        <div class="agent-actions">
          <%= link_to "Test", test_agent_path(agent[:name]), class: "btn btn-primary" %>
          <%= link_to "Prompts", prompts_agent_path(agent[:name]), class: "btn btn-secondary" %>
        </div>
      </div>
    <% end %>
  </div>
</div>
```

## Phase 3: ActionPrompt Studio (Electron App)

### 3.1 Project Structure

```
actionprompt-studio/
├── package.json
├── electron.config.js
├── main/
│   ├── index.js
│   ├── api-client.js
│   ├── ipc-handlers.js
│   └── menu.js
├── renderer/
│   ├── src/
│   │   ├── App.tsx
│   │   ├── components/
│   │   │   ├── AgentExplorer.tsx
│   │   │   ├── PromptComposer.tsx
│   │   │   ├── ResponseViewer.tsx
│   │   │   └── CollectionManager.tsx
│   │   ├── features/
│   │   │   ├── agents/
│   │   │   ├── prompts/
│   │   │   └── collections/
│   │   └── services/
│   │       ├── api.ts
│   │       └── storage.ts
│   └── index.html
└── shared/
    ├── types/
    └── schemas/
```

### 3.2 Main Process Implementation

```javascript
// main/api-client.js
const axios = require('axios');

class RailsAPIClient {
  constructor(baseURL) {
    this.client = axios.create({
      baseURL,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      }
    });
  }
  
  async discoverAgents() {
    const response = await this.client.get('/api/agents');
    return response.data;
  }
  
  async getAgentSchema(agentClass) {
    const response = await this.client.get(`/api/agents/${agentClass}/schema`);
    return response.data;
  }
  
  async generatePrompt(agentClass, action, params) {
    const response = await this.client.post(`/api/agents/${agentClass}/${action}`, {
      params,
      stream: false
    });
    return response.data;
  }
  
  async streamGeneration(agentClass, action, params, onChunk) {
    const response = await this.client.post(`/api/agents/${agentClass}/${action}`, {
      params,
      stream: true
    }, {
      responseType: 'stream'
    });
    
    response.data.on('data', chunk => {
      onChunk(JSON.parse(chunk.toString()));
    });
  }
}

module.exports = RailsAPIClient;
```

### 3.3 Renderer Implementation (React)

```typescript
// renderer/src/components/PromptComposer.tsx
import React, { useState } from 'react';
import { Editor } from '@monaco-editor/react';

interface PromptComposerProps {
  agent: Agent;
  action: Action;
  onSubmit: (prompt: Prompt) => void;
}

export const PromptComposer: React.FC<PromptComposerProps> = ({ 
  agent, 
  action, 
  onSubmit 
}) => {
  const [messages, setMessages] = useState<Message[]>([]);
  const [currentMessage, setCurrentMessage] = useState('');
  const [role, setRole] = useState<'user' | 'system'>('user');
  const [params, setParams] = useState<Record<string, any>>({});
  
  const handleSubmit = () => {
    const prompt: Prompt = {
      agent: agent.name,
      action: action.name,
      messages: [...messages, { role, content: currentMessage }],
      params
    };
    onSubmit(prompt);
  };
  
  return (
    <div className="prompt-composer">
      <div className="messages-list">
        {messages.map((msg, idx) => (
          <MessageCard key={idx} message={msg} />
        ))}
      </div>
      
      <div className="message-editor">
        <select value={role} onChange={e => setRole(e.target.value as any)}>
          <option value="user">User</option>
          <option value="system">System</option>
        </select>
        
        <Editor
          height="200px"
          defaultLanguage="markdown"
          value={currentMessage}
          onChange={value => setCurrentMessage(value || '')}
          options={{
            minimap: { enabled: false },
            lineNumbers: 'off'
          }}
        />
      </div>
      
      <ParametersEditor 
        schema={action.parameters}
        values={params}
        onChange={setParams}
      />
      
      <button onClick={handleSubmit}>Generate</button>
    </div>
  );
};
```

### 3.4 API Endpoints for Studio

```ruby
# app/controllers/api/agents_controller.rb
module Api
  class AgentsController < ApplicationController
    skip_before_action :verify_authenticity_token
    
    def index
      agents = discover_agents
      render json: agents
    end
    
    def schema
      agent_class = params[:id].constantize
      render json: {
        name: agent_class.name,
        actions: agent_class.action_methods.map do |action|
          {
            name: action,
            schema: load_action_schema(agent_class, action)
          }
        end
      }
    end
    
    def generate
      agent_class = params[:agent_id].constantize
      action = params[:action]
      
      generation = agent_class.with(params[:params])
                              .public_send(action)
      
      if params[:stream]
        stream_response(generation)
      else
        render json: generation.generate_now
      end
    end
    
    private
    
    def stream_response(generation)
      response.headers['Content-Type'] = 'text/event-stream'
      response.headers['Cache-Control'] = 'no-cache'
      
      generation.on_chunk do |chunk|
        response.stream.write("data: #{chunk.to_json}\n\n")
      end
      
      generation.generate_now
    ensure
      response.stream.close
    end
  end
end
```

## Phase 4: Integration & Migration

### 4.1 Gem Structure

```
activeagent-solid/
├── lib/
│   ├── solid_agent.rb
│   ├── solid_agent/
│   │   ├── version.rb
│   │   ├── engine.rb
│   │   ├── models/
│   │   ├── controllers/
│   │   ├── services/
│   │   └── extensions/
│   └── generators/
│       └── solid_agent/
│           ├── install_generator.rb
│           └── templates/
├── app/
│   ├── assets/
│   ├── controllers/
│   ├── models/
│   └── views/
├── config/
│   └── routes.rb
├── solid_agent.gemspec
└── README.md
```

### 4.2 Installation Generator

```ruby
# lib/generators/solid_agent/install_generator.rb
module SolidAgent
  class InstallGenerator < Rails::Generators::Base
    source_root File.expand_path('templates', __dir__)
    
    def create_initializer
      template 'solid_agent.rb', 'config/initializers/solid_agent.rb'
    end
    
    def create_migrations
      migration_template(
        'create_solid_agent_tables.rb',
        'db/migrate/create_solid_agent_tables.rb'
      )
    end
    
    def mount_engine
      route "mount SolidAgent::Dashboard => '/admin/agents'"
    end
    
    def add_api_routes
      route <<~RUBY
        namespace :api do
          resources :agents do
            member do
              get :schema
              post ':action/generate', action: :generate
            end
          end
        end
      RUBY
    end
  end
end
```

### 4.3 Configuration

```ruby
# config/initializers/solid_agent.rb
SolidAgent.configure do |config|
  # Persistence settings
  config.auto_persist = Rails.env.production?
  config.persist_system_messages = false
  config.max_message_length = 10_000
  
  # Evaluation settings
  config.enable_evaluations = true
  config.evaluation_queue = :default
  
  # Dashboard settings
  config.dashboard.enabled = true
  config.dashboard.authentication = :devise  # or :basic_auth
  config.dashboard.authorize_with do
    redirect_to '/' unless current_user&.admin?
  end
  
  # API settings
  config.api.enabled = true
  config.api.rate_limit = 100  # requests per minute
  config.api.cors_origins = ['http://localhost:3000']
end
```

## Phase 5: Testing Strategy

### 5.1 Test Coverage Requirements

```ruby
# spec/solid_agent/models/conversation_spec.rb
RSpec.describe SolidAgent::Conversation do
  describe 'persistence' do
    it 'tracks conversation lifecycle' do
      conversation = create(:conversation)
      message = conversation.messages.create!(role: 'user', content: 'Hello')
      generation = message.create_generation!(
        provider: 'openai',
        model: 'gpt-4',
        prompt_tokens: 10,
        completion_tokens: 20
      )
      
      expect(conversation.total_tokens).to eq(30)
    end
  end
end

# spec/features/dashboard_spec.rb
RSpec.describe 'Dashboard', type: :feature do
  scenario 'viewing agent metrics' do
    visit '/admin/agents'
    expect(page).to have_content('ActiveAgent Dashboard')
    expect(page).to have_css('.agent-card', count: Agent.count)
  end
end
```

## Deployment Strategy

### Stage 1: Core SolidAgent (Weeks 1-4)
- Implement database schema
- Create ActiveRecord models
- Add persistence hooks to ActiveAgent
- Write comprehensive tests

### Stage 2: Dashboard Engine (Weeks 5-6)
- Build Rails engine structure
- Implement dashboard controllers/views
- Add authentication/authorization
- Create API endpoints

### Stage 3: ActionPrompt Studio (Weeks 7-10)
- Set up Electron project
- Build React UI components
- Implement Rails API client
- Add collection management

### Stage 4: Integration & Testing (Weeks 11-12)
- End-to-end testing
- Performance optimization
- Documentation
- Beta release

## Success Metrics

1. **Technical Metrics**
   - 90%+ test coverage
   - < 100ms persistence overhead
   - < 500ms dashboard load time

2. **Feature Completeness**
   - All planned models implemented
   - Dashboard fully functional
   - Studio MVP complete

3. **User Adoption**
   - 10+ beta users
   - Positive feedback on usability
   - Active usage in production

## Risk Mitigation

1. **Performance Impact**
   - Use async persistence
   - Implement caching layer
   - Database indexing strategy

2. **Backward Compatibility**
   - Optional opt-in via configuration
   - Maintain existing API
   - Gradual migration path

3. **Complexity Management**
   - Modular architecture
   - Clear separation of concerns
   - Comprehensive documentation