# Active Agent

## Install

### Gemfile
`gem 'activeagent', require: 'active_agent'`

### CLI
`gem install activeagent`

### Rails Generator
After installing the gem, run the Rails installation generator:

```bash
$ rails generate active_agent:install
```

This will create:
```
create  config/initializers/active_agent.rb
create  config/active_agent.yml
create  app/agents/application_agent.rb
create  app/agents
```

- An initializer that uses default configurations 
```ruby
# config/initializers/active_agent.rb
ActiveAgent.load_configuration(Rails.root.join('config', 'active_agent.yml'))
```
- A YAML configuration file for provider settings, such as OpenAI and might include environment-specific configurations:
```yaml
# config/active_agent.yml
development:
  openai:
    service: "OpenAI"
    api_key: <%= Rails.application.credentials.dig(:openai, :api_key) %>
    model: "gpt-3.5-turbo"
    temperature: 0.7

production:
  openai:
    service: "OpenAI"
    api_key: <%= Rails.application.credentials.dig(:openai, :api_key) %>
    model: "gpt-3.5-turbo"
    temperature: 0.7

```
- A base application agent class
```ruby
# app/agents/application_agent.rb
class ApplicationAgent < ActiveAgent::Base
  layout 'agent'

  def prompt
    super { |format| format.text { render plain: params[:message] } }
  end
```
- The agents directory structure

## Agent
Create agents that take instructions, prompts, and perform actions

### Rails Generator
To use the Rails Active Agent generator to create a new agent and the associated views for the requested action prompts:

```bash
$ rails generate active_agent:agent travel search book plans 
```
This will create:
```
create  app/agents/travel_agent.rb
create  app/views/agents/travel/search.text.erb
create  app/views/agents/travel/book.text.erb
create  app/views/agents/travel/plans.text.erb
```

The generator creates:
- An agent class inheriting from ApplicationAgent
- Text template views for each action
- Action methods in the agent class for processing prompts

### Agent Actions
```ruby
class TravelAgent < ApplicationAgent
  def search
    
    prompt { |format| format.text { render plain: "Searching for travel options" } }
  end

  def book
    prompt { |format| format.text { render plain: "Booking travel plans" } }
  end

  def plans
    prompt { |format| format.text { render plain: "Making travel plans" } }
  end
end
```

## Action Prompt

Action Prompt provides the structured interface for composing AI interactions through messages, actions/tools, and conversation context. [Read more about Action Prompt](lib/active_agent/action_prompt/README.md)

```ruby
agent.prompt(message: "Find hotels in Paris", 
      actions: [{name: "search", params: {query: "hotels paris"}}])
```

The prompt interface manages:
- Message content and roles (system/user/assistant)
- Action/tool definitions and requests
- Headers and context tracking
- Content types and multipart handling

### Generation Provider 

Generation Provider defines how prompts are sent to AI services for completion and embedding generation. [Read more about Generation Providers](lib/active_agent/generation_provider/README.md)

```ruby
class VacationAgent < ActiveAgent::Base
  # Try not to get too model-rous with the parameters!
  generate_with :openai, 
  model: "gpt-4",
  temperature: 0.7

  # Embed yourself in the joy of vector search
  embed_with :openai,
  model: "text-embedding-ada-002" 
end
```

Providers handle:
- API client configuration
- Prompt/completion generation
- Stream processing
- Embedding generation  
- Context management
- Error handling

### Queue Generation

Active Agent also supports queued generation with Active Job using a common Generation Job interface.

### Perform actions

Active Agents can define methods that are autoloaded as callable tools. These actions’ default schema will be provided to the agent’s context as part of the prompt request to the Generation Provider.

## Actions

```ruby
def get_cat_image_base64  
  uri = URI("https://cataas.com/cat")  
  response = Net::HTTP.get_response(uri)

  if response.is_a?(Net::HTTPSuccess)  
    image_data = response.body  
    Base64.strict_encode64(image_data)  
  else  
    raise "Failed to fetch cat image. Status code: #{response.code}"  
  end  
end

class SupportAgent < ActiveAgent  
  generate_with :openai,  
    model: "gpt-4o",  
    instructions: "Help people with their problems",  
    temperature: 0.7

   def get_cat_image  
    prompt { |format| format.text { render plain: get_cat_image_base64 } }  
  end  
end  
```

## Prompts

### Basic 

#### Plain text prompt and response templates

### HTML

### Action Schema JSON

response = SupportAgent.prompt(‘show me a picture of a cat’).generate_now

response.message
