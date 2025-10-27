---
title: Rails Integration
---
# {{ $frontmatter.title }}

## Installation

Install ActiveAgent in your Rails application:

```bash
rails generate active_agent:install
```

Creates:
- `config/active_agent.yml` - Provider configuration
- `app/agents/application_agent.rb` - Base agent class

Skip configuration file creation:

```bash
rails generate active_agent:install --skip-config
```

## Configuration

### Automatic Loading

ActiveAgent's Railtie automatically loads `config/active_agent.yml` when your Rails app starts. No manual initialization required.

```yaml
# config/active_agent.yml
openai: &openai
  service: "OpenAI"
  access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
  model: "gpt-4o"

development:
  openai:
    <<: *openai
    model: "gpt-4o-mini"  # Cheaper model for development

production:
  openai:
    <<: *openai
```

See [Configuration](/framework/configuration) for details on provider setup and configuration hierarchy.

### Logger

ActiveAgent inherits `Rails.logger` automatically:

```ruby
# config/environments/development.rb
config.log_level = :debug  # Show all ActiveAgent instrumentation events

# config/environments/production.rb
config.log_level = :info   # Only important operations
```

See [Instrumentation](/framework/instrumentation) for event monitoring and custom logging.

## Generators

### Creating Agents

Generate an agent with actions:

```bash
rails generate active_agent:agent support respond
```

Creates:
```
app/agents/support_agent.rb
app/views/agents/support/instructions.md.erb
app/views/agents/support/respond.md.erb
test/docs/support_agent_test.rb
```

Multiple actions:

```bash
rails generate active_agent:agent inventory search update delete
```

Namespaced agents:

```bash
rails generate active_agent:agent admin/user create
```

### Template Formats

Default markdown format:

```bash
rails generate active_agent:agent support respond
# Creates: respond.md.erb
```

Text format:

```bash
rails generate active_agent:agent support respond --format=text
# Creates: respond.text.erb
```

### JSON Response Formats

Generate with JSON schema validation:

```bash
rails generate active_agent:agent data parse --json-schema
```

Creates:
```ruby
# app/agents/data_agent.rb
class DataAgent < ApplicationAgent
  def parse
    prompt(params[:message], response_format: :json_schema)
  end
end
```

And generates schema file:
```
app/views/agents/data/parse.json
```

JSON object without schema validation:

```bash
rails generate active_agent:agent data parse --json-object
```

Creates agent with `response_format: :json_object` but no schema file.

## Background Jobs

### Active Job Integration

Queue generations for background processing with any Active Job backend (Sidekiq, Resque, etc.):

```ruby
class SupportAgent < ApplicationAgent
  generate_with :openai

  def respond
    prompt message: params[:message]
  end
end

# Queue for background processing
SupportAgent.with(message: "Help!").respond.generate_later(queue: :agents)
```

### Custom Queue Configuration

```ruby
class PriorityAgent < ApplicationAgent
  self.generate_later_queue_name = :high_priority
end
```

Configure your Active Job adapter in `config/application.rb`:

```ruby
config.active_job.queue_adapter = :sidekiq
```

## Controllers

Integrate agents into controllers for user-facing features:

```ruby
class ChatController < ApplicationController
  def create
    generation = ChatAgent
      .with(message: params[:message], user_id: current_user.id)
      .respond
      .generate_later

    render json: { status: "processing" }
  end
end
```

## Models and Services

Call agents from existing business logic:

```ruby
class Document < ApplicationRecord
  after_create :extract_metadata

  private

  def extract_metadata
    DataExtractionAgent
      .with(content: body, document_id: id)
      .extract
      .generate_later
  end
end
```

## Related Documentation

- **[Configuration](/framework/configuration)** - Environment-specific settings and YAML configuration
- **[Instrumentation](/framework/instrumentation)** - Rails.logger integration and event monitoring
